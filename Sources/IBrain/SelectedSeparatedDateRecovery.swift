import Foundation

/// Native scalar recovery from an already semantically selected, proven date.
/// The original quote remains authoritative. Two printed year digits never
/// establish a century; a partial date stays partial, with no capture fallback.
public enum SelectedSeparatedDateRecovery {
    public static let version = "selected-separated-named-date-v1"
    private struct Parts { let year: Int?; let shortYear: Int?; let month: Int; let day: Int; let weekday: Int?; let quote: String }
    internal static func applies(to text:String) -> Bool {
        let names="January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec"
        let pattern="(?:[0-9]{1,2}\\s*[-/.]\\s*(?:"+names+")|(?:"+names+")\\s*[-/.]\\s*[0-9]{1,2})"
        return text.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil
    }
    private static func parse(_ text: String) -> Parts? {
        let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
        let names = Array(Set(months.flatMap { [$0,String($0.prefix(3))] } + ["sept"])).sorted { $0.count > $1.count }.joined(separator:"|")
        let weekdays = ["sun","mon","tue","wed","thu","fri","sat"]
        let prefix = #"(?<![\p{L}\p{N}/.\-])(?:(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sun|Mon|Tue|Wed|Thu|Fri|Sat)\.?[ ,]+)?"#
        let separator = #"\s*[-/.]\s*"#
        let ending = #"(?:\s*[-/.]\s*([0-9]{4}|[0-9]{2}))?(?![\p{L}\p{N}/.\-])"#
        let patterns = [(prefix + "([0-9]{1,2})" + separator + "(" + names + ")" + ending,false),
                        (prefix + "(" + names + ")" + separator + "([0-9]{1,2})" + ending,true)]
        var found: [Parts] = []
        for (pattern,monthFirst) in patterns {
            guard let regex = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return nil }
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                func word(_ index:Int) -> String { Range(match.range(at:index),in:text).map { String(text[$0]) } ?? "" }
                guard let range = Range(match.range,in:text) else { return nil }
                let name = word(monthFirst ? 2 : 3).lowercased(), rawYear = word(4)
                guard let month = months.firstIndex(where: { $0 == name || $0.prefix(3) == name || $0 == "september" && name == "sept" }).map({$0+1}),
                      let day = Int(word(monthFirst ? 3 : 2)) else { return nil }
                let year = rawYear.count == 4 ? Int(rawYear) : nil, shortYear = rawYear.count == 2 ? Int(rawYear) : nil
                let weekday = word(1).isEmpty ? nil : weekdays.firstIndex(of:String(word(1).lowercased().prefix(3))).map {$0+1}
                // Never salvage a month/day prefix while dropping malformed year
                // glyphs, a second date, unsupported continuation or extra digits.
                let tail = String(text[range.upperBound...])
                if tail.range(of:#"^\s*[-/.,]\s*[\p{L}\p{N}]"#,options:.regularExpression) != nil || tail.range(of:#"^\s+[0-9]{2,4}(?![\p{L}\p{N}:])"#,options:.regularExpression) != nil { return nil }
                guard year.map({ (1...9999).contains($0) }) ?? true,
                      valid(year:year,month:month,day:day,weekday:weekday) else { return nil }
                found.append(Parts(year:year,shortYear:shortYear,month:month,day:day,weekday:weekday,quote:String(text[range])))
            }
        }
        guard found.count == 1 else { return nil }
        // A second ordinary spaced named date is a different candidate, too.
        // Do not accept just the separated date in a mixed-format date range.
        let ordinaryYear = #"(?:[, ]+([0-9]{4}|[0-9]{2}))?(?![\p{L}\p{N}/.\-])"#
        let ordinary = [prefix + "(?:"+names+")\\.?\\s+[0-9]{1,2}" + ordinaryYear,
                        prefix + "[0-9]{1,2}\\s+(?:"+names+")" + ordinaryYear]
        for pattern in ordinary {
            if let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive),
               regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil { return nil }
        }
        return found[0]
    }
    private static func valid(year:Int?,month:Int,day:Int,weekday:Int?) -> Bool {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let c=DateComponents(year:year ?? 2000,month:month,day:day)
        guard let d=calendar.date(from:c),calendar.dateComponents([.year,.month,.day],from:d)==c else{return false}
        return year == nil || weekday.map {calendar.component(.weekday,from:d)==$0} ?? true
    }
    public static func project(_ p:MemoryProjection,sources:[SourceSnapshot]) throws -> MemoryProjection {
        guard Set(sources.map{$0.reference.id}).count==sources.count,
              sources.allSatisfy({$0.scope==p.scope && Set($0.observations.map(\.id)).count==$0.observations.count}),
              p.sources.isSubset(of:Set(sources.map(\.reference))) else {throw MemoryError.invalidSnapshot}
        let a=p.appointment,d=a.date,proofs=p.support.filter{$0.field == .date}
        guard proofs.count==1,let proof=proofs.first,proof.origin == .observed,d.certainty == .explicit,
              d.captureYearDerivation==nil,d.temporalDerivation==nil,let raw=d.printedDateText else{return p}
        func proven(_ anchor:EvidenceAnchor)->Bool {sources.contains{s in s.reference==anchor.source && s.observations.contains{$0.id==anchor.observationID && $0.kind == .text && !anchor.quote.isEmpty && $0.value.contains(anchor.quote)}}}
        guard proof.anchors.allSatisfy(proven) else {throw MemoryError.invalidEvidence}
        guard let original=proof.anchors.first(where:{$0.quote==raw}),let parsed=parse(raw) else{return p}
        // A known century must already be independently supported; this parser
        // never creates one from a two-digit year or silently changes it.
        let year=parsed.year ?? d.year
        guard d.year.map({$0==year}) ?? true,parsed.shortYear.map({ short in year.map{$0 % 100 == short} ?? true }) ?? true,
              d.month.map({$0==parsed.month}) ?? true,d.day.map({$0==parsed.day}) ?? true,
              valid(year:year,month:parsed.month,day:parsed.day,weekday:parsed.weekday) else{return p}
        guard year != d.year || parsed.month != d.month || parsed.day != d.day else{return p}
        var anchors=proof.anchors
        let selected=EvidenceAnchor(source:original.source,observationID:original.observationID,quote:parsed.quote)
        if !anchors.contains(selected){anchors.append(selected)}
        let next=EventDate(year:year,month:parsed.month,day:parsed.day,hour:d.hour,minute:d.minute,timeZoneID:d.timeZoneID,utcOffsetSeconds:d.utcOffsetSeconds,certainty:d.certainty,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
        return MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,
            appointment:AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:next,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress),
            support:p.support.map{$0.field == .date ? FieldSupport(field:.date,origin:proof.origin,anchors:anchors,confidence:proof.confidence,extractorVersion:proof.extractorVersion+"/"+version):$0},documentOnlyWithoutDate:p.documentOnlyWithoutDate ?? false)
    }
}
