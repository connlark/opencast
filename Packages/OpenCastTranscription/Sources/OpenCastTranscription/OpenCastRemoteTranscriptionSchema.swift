/// Every top-level payload carries `schema_version`. A higher version decodes if compatible,
/// and unknown enum values are preserved, never dropped.
public enum OpenCastRemoteTranscriptionSchema {
    public static let version = 1
}
