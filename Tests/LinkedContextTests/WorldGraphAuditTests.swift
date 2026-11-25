import Foundation
import IBrain
import IBrainSemantics
import Testing

@Suite struct WorldGraphAuditTests {
    @Test func appointmentProjectionKeepsVenueAndPerformerRolesSeparate() throws {
        let fixture = try Fixture()
        let base = fixture.current
        let original = base.appointment
        let anchor = try #require(base.support.first?.anchors.first)
        let admitted = AppointmentProjection(title: original.title, venue: original.venue, date: original.date,
            performer: anchor.quote)
        let projection = MemoryProjection(recordID: base.recordID, recordRevision: base.recordRevision, scope: base.scope,
            appointment: admitted, support: base.support + [.init(field: .performer, anchors: [anchor], extractorVersion: "authored")])
        let identities = AppointmentWorldIdentities(eventID: "event", venueID: "venue", performerID: "performer", revision: 2)
        let entities = try AppointmentWorldCompiler.compile(projection, identities: identities, policy: .typedTemporalValuesV2)
        let event = try #require(entities.first { $0.kind == .event })
        #expect(entities.first { $0.recordID == "venue" }?.kind == .place)
        #expect(entities.first { $0.recordID == "performer" }?.kind == .unspecified)
        #expect(event.claims.first { $0.predicate == .locatedAt }?.value == .entity("venue"))
        #expect(event.claims.first { $0.predicate == .performedBy }?.value == .entity("performer"))
        #expect(event.claims.first { $0.predicate == .scheduledAt }?.value == .date(original.date))
        #expect(throws: SemanticError.unsupportedEvidence) {
            _ = try AppointmentWorldCompiler.compile(projection,
                identities: .init(eventID: "event", venueID: "event", performerID: "performer", revision: 2))
        }
    }

    @Test func everyEntityAndPredicateSurvivesReceiptProjectionAndScopedQuery() async throws {
        let kinds: [(WorldEntityKind, String)] = [(.event, "Dawn String Concert"), (.person, "Mina Bell"),
            (.organization, "Quayside Arts"), (.place, "Blue Hall"), (.document, "Concert programme"),
            (.object, "Small lino print"), (.unspecified, "Morning Players")]
        let additional: [(WorldEntityKind, WorldPredicate, String)] = [
            (.event, .status, "Scheduled"), (.event, .category, "concert"), (.person, .alias, "M. Bell"),
            (.place, .address, "18 Sedge Lane"), (.object, .color, "indigo"), (.object, .material, "paper"),
            (.document, .identifier, "P-0326"), (.document, .description, "Programme for the spring concert"),
            (.document, .observedText, "Keep this programme"), (.object, .visualLabel, "lino print")
        ]
        let edges: [(WorldEntityKind, WorldPredicate, WorldEntityKind)] = [(.event, .locatedAt, .place),
            (.event, .performedBy, .person), (.event, .performedBy, .unspecified),
            (.document, .issuedBy, .organization), (.document, .about, .event), (.document, .depicts, .object)]
        #expect(Set(kinds.map(\.0)) == Set(WorldEntityKind.allCases))
        #expect(Set(additional.map(\.1) + edges.map(\.1) + [.name, .scheduledAt]) == Set(WorldPredicate.allCases))

        let names = Dictionary(uniqueKeysWithValues: kinds)
        let namesObserved = kinds.map { kind, name in
            SourceObservation(id: kind.rawValue, value: kind == .event ? name + " — spring programme" : name)
        }
        let textObserved = additional.map { _, predicate, text in
            SourceObservation(id: predicate.rawValue, kind: predicate == .visualLabel ? .visualLabel : .text, value: text)
        }
        let relation = SourceObservation(id: "sentence", value: "Dawn String Concert by Mina Bell and Morning Players at Blue Hall. Concert programme about Dawn String Concert, issued by Quayside Arts and depicting Small lino print.")
        let date = SourceObservation(id: "date", value: "March 3, 2026")
        let clocks = SourceObservation(id: "clocks", value: "Doors open at 17:30 / Einlass 18.30 / Beginn 20.00")
        let scope = MemoryScope(ownerID: "fixture", namespace: "audited-graph")
        let reference = SourceReference(id: "concert-programme", revision: 1, fingerprint: "authored-programme")
        let source = SourceSnapshot(reference: reference, scope: scope,
            observations: namesObserved + textObserved + [relation, date, clocks])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(directory: directory, scope: scope)
        defer { try? FileManager.default.removeItem(at: directory) }
        let permit = try await store.synchronize(.init(sources: [source], records: kinds.map { kind, _ in
            .init(id: kind.rawValue, revision: 1, sources: [reference], recordKind: .worldEntity)
        }))
        let prepared = try await WorldSourceGraphInterpretation.prepare(sourceID: reference.id, store: store,
            permit: permit, taskID: "scope-graph", temporalPolicy: .germanLabelledClocksV3)
        let day = try #require(prepared.task.temporalSpans.first { $0.observationID == date.id && $0.kind == .date })
        let start = try #require(prepared.task.temporalSpans.first { $0.observationID == clocks.id && $0.time?.hour == 20 })
        let doors = try #require(prepared.task.temporalSpans.first { $0.observationID == clocks.id && $0.time?.hour == 18 })
        let englishDoors = try #require(prepared.task.temporalSpans.first { $0.observationID == clocks.id && $0.time?.hour == 17 })
        func nodes(_ clock: TemporalEvidenceSpan) -> [WorldGraphNode] {
            kinds.map { kind, name in
                let properties = additional.filter { $0.0 == kind }.map { _, predicate, text in
                    WorldGraphProperty(predicate: predicate, quotes: [.init(observationID: predicate.rawValue, quote: text)])
                }
                return WorldGraphNode(localID: kind.rawValue, kind: kind,
                    properties: [.init(predicate: .name, quotes: [.init(observationID: kind.rawValue, quote: name)])] + properties,
                    starts: kind == .event ? [.init(dateSpanID: day.id, timeSpanID: clock.id)] : [])
            }
        }
        func edge(_ subject: WorldEntityKind, _ predicate: WorldPredicate, _ target: WorldEntityKind,
                  includeVisual: Bool = false) -> WorldGraphEdge {
            var quotes: [WorldGraphQuote] = [.init(observationID: subject.rawValue, quote: names[subject]!),
                .init(observationID: target.rawValue, quote: names[target]!), .init(observationID: relation.id, quote: relation.value)]
            if includeVisual { quotes.append(.init(observationID: WorldPredicate.visualLabel.rawValue, quote: "lino print")) }
            return .init(subject: subject.rawValue, predicate: predicate, target: target.rawValue, quotes: quotes)
        }
        func compile(_ proposed: [WorldGraphEdge], clock: TemporalEvidenceSpan) async throws -> PreparedWorldGraphDraft {
            let proposal = WorldGraphProposal(coverage: .complete, nodes: nodes(clock), edges: proposed)
            let receipt = WorldGraphReceipt(provider: "fixture", model: "authored", requestSHA256: try prepared.task.digest(),
                proposal: proposal, elapsedSeconds: 0)
            return try await WorldSourceGraphInterpretation.compile(receipt, for: prepared, store: store)
        }

        for invalid in [edge(.document, .depicts, .object), edge(.person, .about, .event),
                        edge(.object, .issuedBy, .person), edge(.event, .performedBy, .place)] {
            await #expect(throws: SemanticError.invalidReceipt) { _ = try await compile([invalid], clock: start) }
        }
        let valid = edges.map { edge($0.0, $0.1, $0.2, includeVisual: $0.1 == .depicts) }
        await #expect(throws: SemanticError.invalidReceipt) { _ = try await compile(valid, clock: doors) }
        await #expect(throws: SemanticError.invalidReceipt) { _ = try await compile(valid, clock: englishDoors) }
        let eventName = try #require(namesObserved.first { $0.id == WorldEntityKind.event.rawValue })
        let proper = valid[0]
        let broader = WorldGraphEdge(subject: proper.subject, predicate: proper.predicate, target: proper.target,
            quotes: proper.quotes.map { $0.observationID == eventName.id ? .init(observationID: eventName.id, quote: eventName.value) : $0 })
        await #expect(throws: SemanticError.invalidReceipt) { _ = try await compile([broader], clock: start) }

        let draft = try await compile(valid, clock: start)
        let projected = try await WorldSourceGraphInterpretation.project(draft,
            hostIdentities: Dictionary(uniqueKeysWithValues: kinds.map { ($0.0.rawValue, $0.0.rawValue) }),
            recordRevision: 1, store: store)
        _ = try await store.applyWorldBatch(projected.map { WorldMemoryWrite($0) }, permit: permit)
        for (kind, name) in kinds {
            let extras = additional.filter { $0.0 == kind }
            let request = [WorldPredicate.name] + extras.map(\.1) + (kind == .event ? [.scheduledAt] : [])
            let answer = try await store.queryWorld(.init(kind: kind, requested: request), requestID: UUID(),
                permit: store.permit(), sourceScope: [reference])
            let item = try #require(answer.matches.first)
            #expect(answer.matches.map(\.recordID) == [kind.rawValue])
            #expect(item.sources == [reference])
            #expect(item.fields.first?.claims.first?.value == .text(name))
            for (_, predicate, value) in extras {
                #expect(item.fields.first(where: { $0.predicate == predicate })?.claims.first?.value == .text(value))
            }
            if kind == .event {
                let field = try #require(item.fields.first { $0.predicate == .scheduledAt })
                #expect(field.state == .partial)
                let claim = try #require(field.claims.first)
                if case .date(let date) = claim.value {
                    #expect([date.year, date.month, date.day, date.hour, date.minute] == [2026, 3, 3, 20, 0])
                    #expect(date.timeZoneID == nil && date.printedTimeText == "Beginn 20.00")
                } else { Issue.record("Printed start is absent") }
            }
        }
        for (kind, predicate, target) in edges {
            let query = WorldMemoryQuery(kind: kind,
                constraints: [.init(path: [predicate], predicate: .name, value: .text(names[target]!))], requested: [predicate])
            let answer = try await store.queryWorldCurrent(query, requestID: UUID())
            #expect(answer.matches.map(\.recordID) == [kind.rawValue])
            #expect(answer.matches.first?.sources == [reference])
        }
        let requestID = UUID()
        let request = try await WorldQuestionPlanning.prepare(question: "Which concert was performed by Mina Bell?",
            taskID: "semantic-relationship", requestID: requestID, store: store, permit: store.permit())
        let plan = WorldQuestionPlan(operation: .search, kind: "event",
            conditions: [.init(path: [.performedBy], predicate: .name, quotes: ["Mina Bell"])], requested: [.name, .performedBy])
        let receipt = WorldQuestionPlanReceipt(provider: "fixture", model: "authored", requestSHA256: try request.task.digest(),
            plan: plan, elapsedSeconds: 0)
        let compiled = try WorldQuestionPlanning.compile(receipt, for: request)
        switch try await WorldQuestionPlanning.execute(compiled, prepared: request, store: store, activeRequestID: requestID) {
        case .answer(let answer): #expect(answer.matches.map(\.recordID) == [WorldEntityKind.event.rawValue])
        case .detail: Issue.record("Expected scoped relation search")
        }
        await store.close()
    }
}
