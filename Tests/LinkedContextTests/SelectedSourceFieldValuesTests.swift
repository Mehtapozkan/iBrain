import Foundation
import Testing
import IBrain
import IBrainSemantics

// Authored offline decisions exercise a contract, never measured model accuracy.
private func valueContext(titles: [String] = ["Event: Night Study"],
                          performers: [String] = ["Performer: Aster: Live"],
                          addresses: [String] = ["Street address: 17 Cedar Lane, Porto"],
                          reference: String? = "Booking reference: XY-42:A",
                          revision: Int = 4, fingerprint: String = "AUTHORED-PIXELS-A",
                          titleOrigin: FactOrigin = .observed, note: String = "Doors open 17:45; start time is separate") -> SelectedSourceFieldValuesContext {
    let scope = MemoryScope(ownerID: "AUTHORED", namespace: "value-contract")
    let ref = SourceReference(id: "photo-A", revision: revision, fingerprint: fingerprint)
    var rows = [SourceObservation(id: "provider", value: "Independent Presenter"),
                SourceObservation(id: "venue", value: "Cedar Hall"),
                SourceObservation(id: "date", value: "9 November 2026"),
                SourceObservation(id: "time", value: "19:20"), SourceObservation(id: "note", value: note)]
    var support: [FieldSupport] = []
    func part(_ field: AppointmentField, _ prefix: String, _ values: [String], origin: FactOrigin = .observed) {
        guard !values.isEmpty else { return }
        let anchors = values.enumerated().map { index, value -> EvidenceAnchor in
            let id = prefix + String(index); rows.append(SourceObservation(id: id, value: value))
            return EvidenceAnchor(source: ref, observationID: id, quote: value)
        }
        support.append(FieldSupport(field: field, origin: origin, anchors: anchors, confidence: 0.7, extractorVersion: "AUTHORED-role-v1"))
    }
    part(.title, "title", titles, origin: titleOrigin); part(.performer, "performer", performers); part(.venueAddress, "address", addresses)
    func anchor(_ id: String) -> EvidenceAnchor { EvidenceAnchor(source: ref, observationID: id, quote: rows.first { $0.id == id }!.value) }
    for (field, ids) in [(AppointmentField.provider, ["provider"]), (.venue, ["venue"]), (.date, ["date", "time"]), (.kind, ["title0"]), (.status, ["title0"])] {
        support.append(FieldSupport(field: field, anchors: ids.map(anchor), extractorVersion: "AUTHORED-role-v1"))
    }
    var booking: EvidenceAnchor?
    if let reference {
        rows.append(SourceObservation(id: "reference", value: reference)); booking = anchor("reference")
    }
    let source = SourceSnapshot(reference: ref, scope: scope, observations: rows)
    let appointment = AppointmentProjection(title: titles.joined(separator: "\n"), provider: "Independent Presenter", venue: "Cedar Hall",
        date: EventDate(year: 2026, month: 11, day: 9, hour: 19, minute: 20, timeZoneID: "Europe/Lisbon", printedDateText: "9 November 2026", printedTimeText: "19:20"),
        kind: .eventTicket, performer: performers.isEmpty ? nil : performers.joined(separator: " / "),
        venueAddress: addresses.isEmpty ? nil : addresses.joined(separator: "\n"))
    return SelectedSourceFieldValuesContext(source: source,
        projection: MemoryProjection(recordID: "native-event-A", recordRevision: 2, scope: scope, appointment: appointment, support: support), bookingReference: booking)
}
private func valueReceipt(_ context: SelectedSourceFieldValuesContext, id: String = "source-values-A",
                          choose: (String) -> String = { _ in "labelledValue" }) throws -> DecisionReceipt {
    let task = try #require(try SelectedSourceFieldValuesInterpreter.task(id: id, context: context))
    return DecisionReceipt(provider: "AUTHORED-OFFLINE-NOT-MODEL", model: "NONE", requestSHA256: try task.digest(),
        answers: Dictionary(uniqueKeysWithValues: task.questions.keys.map { ($0, ChoiceAnswer(choice: choose($0))) }), elapsedSeconds: 0)
}
private func values(_ context: SelectedSourceFieldValuesContext, choose: (String) -> String = { _ in "labelledValue" }) throws -> SelectedSourceFieldValuesResult {
    try SelectedSourceFieldValuesInterpreter.compile(valueReceipt(context, choose: choose), id: "source-values-A", context: context)
}
private func alteredContext(_ context: SelectedSourceFieldValuesContext, source: SourceSnapshot? = nil,
                            projection: MemoryProjection? = nil, reference: EvidenceAnchor?? = nil) -> SelectedSourceFieldValuesContext {
    .init(source: source ?? context.source, projection: projection ?? context.projection, bookingReference: reference ?? context.bookingReference)
}
private func jsonMutate<T: Codable>(_ input: T, _ mutate: (inout [String: Any]) -> Void) throws -> T {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    mutate(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private func emitValueExample(_ name: String, context: SelectedSourceFieldValuesContext, receipt: DecisionReceipt,
                              result: SelectedSourceFieldValuesResult) throws {
    guard let path = ProcessInfo.processInfo.environment["IBRAIN_SELECTED_VALUES_ARTIFACT_DIR"] else { return }
    let directory = URL(fileURLWithPath: path).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(context).write(to: directory.appendingPathComponent("AUTHORED-CONTEXT.json"))
    try encoder.encode(SelectedSourceFieldValuesInterpreter.task(id: "source-values-A", context: context)).write(to: directory.appendingPathComponent("TASK.json"))
    try encoder.encode(receipt).write(to: directory.appendingPathComponent("AUTHORED-NOT-MODEL-RECEIPT.json"))
    try encoder.encode(result).write(to: directory.appendingPathComponent("EXPECTED-RESULT.json"))
}

@Test func selectedValuesExactFieldsRetainFullOriginalSourceAndProof() throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let context = valueContext(), before = try encoder.encode(context), result = try values(context)
    #expect(result.projection.appointment.title == "Night Study")
    #expect(result.projection.appointment.performer == "Aster: Live")
    #expect(result.projection.appointment.venueAddress == "17 Cedar Lane, Porto")
    #expect(result.bookingReference?.valueQuote == "XY-42:A")
    #expect(result.bookingReference?.originalAnchor.quote == "Booking reference: XY-42:A")
    #expect(result.unresolvedFields.isEmpty && result.selections.count == 4)
    #expect(try encoder.encode(context) == before)
    #expect(result.projection.appointment.date == context.projection.appointment.date)
    #expect(result.projection.recordID == context.projection.recordID && result.projection.recordRevision == context.projection.recordRevision)
    #expect(result.projection.support.filter { ![.title, .performer, .venueAddress].contains($0.field) } == context.projection.support.filter { ![.title, .performer, .venueAddress].contains($0.field) })
    for selection in result.selections {
        let bytes = Array(selection.originalAnchor.quote.utf8)
        #expect(Data(bytes[selection.valueUTF8LowerBound..<selection.valueUTF8UpperBound]) == Data(selection.valueQuote.utf8))
        #expect(selection.valueAnchor.source == selection.originalAnchor.source && selection.valueAnchor.observationID == selection.originalAnchor.observationID)
    }
    try emitValueExample("labelled-values", context: context, receipt: valueReceipt(context), result: result)
}

@Test func selectedValuesSamePrefixCanBeGenuineNameWithoutStripping() throws {
    let context = valueContext(titles: ["Event: Horizon"], performers: ["Artist: Unknown"], addresses: [], reference: nil)
    let task = try #require(try SelectedSourceFieldValuesInterpreter.task(id: "source-values-A", context: context))
    #expect(task.questions.count == 2 && task.questions.values.allSatisfy { $0.criteria["wholeQuote"] != nil && $0.criteria["unclear"] != nil })
    let result = try values(context, choose: { _ in "wholeQuote" })
    #expect(result.projection == context.projection && result.unresolvedFields.isEmpty)
    #expect(result.selections.allSatisfy { $0.resolution == .wholeQuote && $0.valueQuote == $0.originalAnchor.quote })
    try emitValueExample("genuine-colons", context: context, receipt: valueReceipt(context, choose: { _ in "wholeQuote" }), result: result)
}

@Test func selectedValuesUnlabelledAndUnknownColonsNeedNoCallAndStayExact() throws {
    let context = valueContext(titles: ["Night Study: Part II"], performers: ["Aster: Live"], addresses: ["17 Cedar Lane"], reference: "XY:42")
    #expect(try SelectedSourceFieldValuesInterpreter.task(id: "source-values-A", context: context) == nil)
    let result = try SelectedSourceFieldValuesInterpreter.compile(nil, id: "source-values-A", context: context)
    #expect(result.projection == context.projection && result.requestSHA256 == nil && result.bookingReference?.valueQuote == "XY:42")
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.compile(valueReceipt(valueContext()), id: "source-values-A", context: context) }
}

@Test func selectedValuesUncertaintyKeepsWholeFieldButOtherFieldsCanResolve() throws {
    let context = valueContext(titles: ["Event: First part", "Title: Second part"])
    let result = try values(context, choose: { $0 == "value_1" ? "unclear" : "labelledValue" })
    #expect(result.unresolvedFields == [.title])
    #expect(result.projection.appointment.title == context.projection.appointment.title)
    #expect(result.projection.support.first { $0.field == .title } == context.projection.support.first { $0.field == .title })
    #expect(result.selections.filter { $0.field == .title }.allSatisfy { $0.resolution == .unresolved && $0.valueQuote == $0.originalAnchor.quote })
    #expect(result.projection.appointment.performer == "Aster: Live" && result.bookingReference?.valueQuote == "XY-42:A")
}

@Test func selectedValuesUncertainReferenceRetainsFullQuoteAndUnresolvedMarker() throws {
    let context = valueContext(titles: ["Plain title"], performers: [], addresses: [], reference: "Booking reference: Unsettled: A")
    let result = try values(context, choose: { _ in "unclear" })
    #expect(result.unresolvedFields == [.bookingReference] && result.projection == context.projection)
    #expect(result.bookingReference?.resolution == .unresolved && result.bookingReference?.valueQuote == context.bookingReference?.quote)
    try emitValueExample("unsettled-reference", context: context, receipt: valueReceipt(context, choose: { _ in "unclear" }), result: result)
}

@Test func selectedValuesDoNotRecursivelyStripGenuineBodyColon() throws {
    let context = valueContext(titles: ["Title: Event: Horizon"], performers: [], addresses: [], reference: "Booking ref: A:B:C")
    let result = try values(context)
    #expect(result.projection.appointment.title == "Event: Horizon" && result.bookingReference?.valueQuote == "A:B:C")
}

@Test func selectedValuesVisitAndAppointmentLabelsShareTheSameGenericBoundary() throws {
    for label in ["Visit", "Appointment", "Purpose", "Event title", "Appointment title"] {
        let context = valueContext(titles: [label + ": Frame consultation: first visit"], performers: [], addresses: [], reference: nil)
        let result = try values(context)
        #expect(result.projection.appointment.title == "Frame consultation: first visit")
        #expect(result.selections.first?.originalAnchor.quote == label + ": Frame consultation: first visit")
    }
}

@Test func selectedValuesUnicodeAndWhitespaceUseExactUTF8SuffixRanges() throws {
    let context = valueContext(titles: ["  EVENT :  Étoile: 夜  "], performers: ["Artists: Åsa & 李"], addresses: ["Street address:  9 São João\n4000 Porto\t"])
    let result = try values(context)
    #expect(result.projection.appointment.title == "Étoile: 夜" && result.projection.appointment.performer == "Åsa & 李")
    #expect(result.projection.appointment.venueAddress == "9 São João\n4000 Porto")
    for part in result.selections {
        #expect(Data(Array(part.originalAnchor.quote.utf8)[part.valueUTF8LowerBound..<part.valueUTF8UpperBound]) == Data(part.valueQuote.utf8))
    }
}

@Test func selectedValuesMultiPartRolesPreserveOrderSeparatorsAndUnlabelledParts() throws {
    let context = valueContext(titles: ["Event: Night Study", "Part II: Dawn"], performers: ["Performer: Aster", "Guest: Punctuation"], addresses: ["Street address: 17 Cedar Lane", "4000 Porto"])
    let result = try values(context)
    #expect(result.projection.appointment.title == "Night Study\nPart II: Dawn")
    #expect(result.projection.appointment.performer == "Aster / Guest: Punctuation")
    #expect(result.projection.appointment.venueAddress == "17 Cedar Lane\n4000 Porto")
    #expect(result.selections.count == 7)
}

@Test func selectedValuesCurrentCorrectionIsNotRewritten() throws {
    let context = valueContext(titles: ["Event: Owner chosen title"], performers: [], addresses: [], reference: nil, titleOrigin: .domainCorrection)
    #expect(try SelectedSourceFieldValuesInterpreter.task(id: "source-values-A", context: context) == nil)
    let result = try SelectedSourceFieldValuesInterpreter.compile(nil, id: "source-values-A", context: context)
    #expect(result.projection == context.projection && result.selections.isEmpty)
}

@Test func selectedValuesBlankSuffixCannotBeChosenAsAValue() throws {
    let context = valueContext(titles: ["Event:  "], performers: [], addresses: [], reference: nil)
    let task = try #require(try SelectedSourceFieldValuesInterpreter.task(id: "source-values-A", context: context))
    #expect(task.questions["value_0"]?.criteria["labelledValue"] == nil)
    #expect(throws: (any Error).self) { try values(context) }
    let unresolved = try values(context, choose: { _ in "unclear" })
    #expect(unresolved.unresolvedFields == [.title] && unresolved.projection == context.projection)
}

@Test func selectedValuesReceiptCannotMoveAcrossSourceRevisionFingerprintOrContext() throws {
    let context = valueContext(), receipt = try valueReceipt(context)
    for other in [valueContext(revision: 5), valueContext(fingerprint: "OTHER-PIXELS"), valueContext(note: "Same source role with different retained context"), valueContext(titles: ["Event: Different title"])] {
        #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.compile(receipt, id: "source-values-A", context: other) }
    }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.compile(receipt, id: "different-native-attempt", context: context) }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.compile(nil, id: "source-values-A", context: context) }
}

@Test func selectedValuesMismatchedQuoteRoleAndReferenceEvidenceAreRejected() throws {
    let context = valueContext()
    let forged = try jsonMutate(context) { object in
        var projection = object["projection"] as! [String: Any], a = projection["appointment"] as! [String: Any]
        a["title"] = "Unsupported clean value"; projection["appointment"] = a; object["projection"] = projection
    }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.task(id: "x", context: forged) }
    let ref = context.source.reference
    for reference in [EvidenceAnchor(source: ref, observationID: "reference", quote: "XY-42:A"),
                      EvidenceAnchor(source: ref, observationID: "reference", quote: "not printed"),
                      EvidenceAnchor(source: SourceReference(id: ref.id, revision: 3, fingerprint: ref.fingerprint), observationID: "reference", quote: context.bookingReference!.quote)] {
        #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.task(id: "x", context: alteredContext(context, reference: .some(reference))) }
    }
    let absent = SourceSnapshot(reference: ref, scope: context.source.scope, observations: context.source.observations.filter { $0.id != "performer0" })
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.task(id: "x", context: alteredContext(context, source: absent)) }
}

@Test func selectedValuesWrongRealReferenceSelectionRequiresNewBoundDecision() throws {
    let context = valueContext(), receipt = try valueReceipt(context)
    let otherReal = EvidenceAnchor(source: context.source.reference, observationID: "venue", quote: "Cedar Hall")
    // SDK value stage does not certify initial role selection; native host must
    // reconstruct it. Changing even a real selected anchor breaks this receipt.
    #expect(throws: (any Error).self) {
        try SelectedSourceFieldValuesInterpreter.compile(receipt, id: "source-values-A", context: alteredContext(context, reference: .some(otherReal)))
    }
}

@Test func selectedValuesRetainedProofReplayRejectsForgedValueRangeOrOriginal() throws {
    let context = valueContext(), receipt = try valueReceipt(context), result = try values(context)
    let encoded = try JSONEncoder().encode(result), restored = try JSONDecoder().decode(SelectedSourceFieldValuesResult.self, from: encoded)
    try SelectedSourceFieldValuesInterpreter.validate(restored, receipt: receipt, id: "source-values-A", context: context)
    for key in ["valueQuote", "valueUTF8LowerBound", "anchorIndex", "resolution", "originalAnchor"] {
        let tampered = try jsonMutate(result) { object in
            var selections = object["selections"] as! [[String: Any]], item = selections[0]
            switch key {
            case "valueQuote": item[key] = "Forged result"
            case "valueUTF8LowerBound": item[key] = 0
            case "anchorIndex": item[key] = 99
            case "resolution": item[key] = "wholeQuote"
            default: var anchor = item[key] as! [String: Any]; anchor["quote"] = "Event: Different"; item[key] = anchor
            }
            selections[0] = item; object["selections"] = selections
        }
        #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.validate(tampered, receipt: receipt, id: "source-values-A", context: context) }
    }
    let forgedProjection = try jsonMutate(result) { object in
        var projection = object["projection"] as! [String: Any], appointment = projection["appointment"] as! [String: Any]
        appointment["title"] = "Invented displayed value"; projection["appointment"] = appointment; object["projection"] = projection
    }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.validate(forgedProjection, receipt: receipt, id: "source-values-A", context: context) }
}

@Test func selectedValuesChangedNativeRecordOrPolicyCannotReuseProof() throws {
    let context = valueContext(), receipt = try valueReceipt(context), result = try values(context)
    let changed = try jsonMutate(context) { object in
        var projection = object["projection"] as! [String: Any]; projection["recordRevision"] = 3; object["projection"] = projection
    }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.validate(result, receipt: receipt, id: "source-values-A", context: changed) }
    let wrongVersion = try jsonMutate(result) { $0["version"] = "not-this-policy" }
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.validate(wrongVersion, receipt: receipt, id: "source-values-A", context: context) }
}

@Test func selectedValuesLegacyHelpersAndDefaultsStayUnchanged() throws {
    let context = valueContext()
    let legacy = try LabelledAppointmentFieldValues.project(context.projection, sources: [context.source])
    #expect(legacy.projection == context.projection && legacy.derivations.isEmpty)
    for policy in [LabelledFieldValuePolicy.explicitColonLabelsV1, .labelledLocationBlocksV2, .labelledVenueComponentsV3] {
        let old = try LabelledAppointmentFieldValues.project(context.projection, sources: [context.source], policy: policy)
        #expect(old.projection == context.projection && old.derivations.isEmpty)
    }
}

@Test func selectedValuesDenseSourceRetainsLastObservationAndRefusesOverflow() throws {
    let context = valueContext()
    let extra = (0..<128).map { SourceObservation(id: "note-\($0)", value: "Retained context \($0)") }
    let dense = SourceSnapshot(reference: context.source.reference, scope: context.source.scope, observations: context.source.observations + extra)
    let task = try #require(try SelectedSourceFieldValuesInterpreter.task(id: "dense", context: alteredContext(context, source: dense)))
    #expect(task.state.contains("Retained context 127") && task.questions.count == 4)
    let tooMany = SourceSnapshot(reference: context.source.reference, scope: context.source.scope, observations: context.source.observations + (0..<4096).map { SourceObservation(id: "overflow-\($0)", value: "x") })
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.task(id: "dense", context: alteredContext(context, source: tooMany)) }
    let tooLarge = SourceSnapshot(reference: context.source.reference, scope: context.source.scope, observations: context.source.observations + [SourceObservation(id: "huge", value: String(repeating: "x", count: 1_048_577))])
    #expect(throws: (any Error).self) { try SelectedSourceFieldValuesInterpreter.task(id: "dense", context: alteredContext(context, source: tooLarge)) }
}

@Test func selectedValuesNarrowedProjectionPassesUnchangedStoreAndColdReconstruction() async throws {
    let context = valueContext(), receipt = try valueReceipt(context), result = try values(context)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let authority = AuthoritySnapshot(sources: [context.source], records: [DomainRecordPin(id: result.projection.recordID, revision: result.projection.recordRevision, sources: result.projection.sources)])
    let store = try MemoryStore(directory: directory, scope: context.source.scope)
    try await store.synchronize(authority)
    let written = try await store.upsert(result.projection, permit: store.permit())
    #expect(written.projection == result.projection)
    await store.close()
    let cold = try MemoryStore(directory: directory, scope: context.source.scope)
    try await cold.synchronize(authority)
    let replayed = try await cold.upsert(result.projection, permit: cold.permit())
    #expect(replayed.projection == result.projection)
    await cold.close()
    let roundtrip = try JSONDecoder().decode(SelectedSourceFieldValuesResult.self, from: JSONEncoder().encode(result))
    try SelectedSourceFieldValuesInterpreter.validate(roundtrip, receipt: receipt, id: "source-values-A", context: context)
}
