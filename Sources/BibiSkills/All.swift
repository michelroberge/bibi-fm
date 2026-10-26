import BibiCore

/// Every skill bibi knows. Swift has no module walking, so new skills are added here.
public enum AllSkills {
    public static let list: [any Skill] = [
        OptimizeStorage(),
        NetIdentify(),
        DevCleanup(),
        SysHealth(),
        SecAudit(),
    ]
}
