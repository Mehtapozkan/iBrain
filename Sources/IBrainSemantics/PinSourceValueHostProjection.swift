import IBrain

/// Pin-owned host shim beside EvidenceQuestionHostInspection. Swift resolves
/// PinMemory's older identically named type before the SDK module, so expose
/// this exact existing SDK operation without copying its parser or policies.
/// Not part of the sealed SDK production manifest; tracked as consumer source.
public enum PinSourceValueHostProjection {
    public static func project(_ input:MemoryProjection,sources:[SourceSnapshot])throws->MemoryProjection {
        try LabelledAppointmentFieldValues.project(input,sources:sources,policy:.labelledVenueComponentsV3).projection
    }
}
