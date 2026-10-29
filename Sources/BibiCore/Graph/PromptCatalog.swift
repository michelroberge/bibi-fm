import Foundation

/// One prompt bibi sends the model, as Settings lists it: the built-in text that ships in code, what it is for,
/// and what Settings needs to try it on its own (its schema and a sample input). The text a call uses is still
/// `PromptBook.text(id, default: builtIn)`: an override in bibi.db wins.
public struct PromptDefinition: Sendable {
    public var id: String
    public var title: String
    public var group: String
    public var purpose: String
    public var builtIn: String
    /// The answer's shape; nil for a fragment that is part of another call's prompt (it can't be tried alone).
    public var schema: Schema?
    /// An input to try it with.
    public var sample: String

    public init(_ id: String, _ title: String, group: String, purpose: String, builtIn: String, schema: Schema? = nil, sample: String = "") {
        self.id = id; self.title = title; self.group = group; self.purpose = purpose; self.builtIn = builtIn
        self.schema = schema; self.sample = sample
    }
}

public enum PromptCatalog {
    public static let chat = "Chat", learning = "Learning", analysis = "Analysis", guidance = "Skill guidance"

    /// bibi's own prompts. Skills add theirs (`Skill.prompts`), and every skill has a guidance prompt (`guidance`).
    public static let core: [PromptDefinition] = [
        PromptDefinition("chat.system", "Chat instructions", group: chat,
                         purpose: "The instructions for every chat turn: who bibi is, when to propose steps, how to write them. The generic skill's guidance is appended.",
                         builtIn: ChatEngine.systemInstructions, schema: ChatEngine.turnSchema(["command"]),
                         sample: "User\nhow much free disk space do I have?"),
        PromptDefinition("chat.tool.command", "Command tool line", group: chat,
                         purpose: "How the `command` tool is listed under Tools in every turn, with example argv. The small model copies these examples closely.",
                         builtIn: ChatEngine.commandTool),
        PromptDefinition("chat.task.answer", "Answer from results", group: chat,
                         purpose: "The task after approved steps ran: answer from what they found.", builtIn: ChatEngine.answerTask),
        PromptDefinition("chat.repair", "Fix refused steps", group: chat,
                         purpose: "Added after the problems with refused steps when the model gets another try.", builtIn: ChatEngine.repairInstruction),
        PromptDefinition("chat.fallback", "Own answer (no tool fits)", group: chat,
                         purpose: "When no tool fits and \"Work it out\" is off, the model answers on its own; nothing on the Mac is checked.",
                         builtIn: ChatEngine.fallbackInstructions, schema: ChatEngine.fallbackSchema, sample: "what does kernel_task do?"),
        PromptDefinition("chat.translate", "Translate to English", group: chat,
                         purpose: "Messages in another language are translated for retrieval (examples, skills and facts are in English).",
                         builtIn: ChatEngine.translateInstructions, schema: ChatEngine.translateSchema,
                         sample: "combien d'espace libre reste-t-il sur mon disque ?"),
        PromptDefinition("chat.compact", "Compact the conversation", group: chat,
                         purpose: "Keeps the running summary short and picks out durable facts to remember.",
                         builtIn: ChatEngine.compactInstructions, schema: ChatEngine.compactSchema,
                         sample: "Summary: (none)\nuser: how much space is free?\nbibi: 112 GB of 494 GB are free on Macintosh HD."),
        PromptDefinition("chat.extract", "Extract notes from output", group: chat,
                         purpose: "Reduces a long command output to at most five lines copied from it. Lines that aren't really in the output are dropped.",
                         builtIn: ChatEngine.extractInstructions, schema: ChatEngine.extractSchema,
                         sample: "Purpose: free disk space\nRequest: how much space is left?\nOutput:\nFilesystem Size Used Avail Capacity Mounted on\n/dev/disk3s1s1 494Gi 10Gi 112Gi 9% /\ndevfs 213Ki 213Ki 0Bi 100% /dev"),
        PromptDefinition("chat.next", "Let bibi look: next step", group: chat,
                         purpose: "With \"Let bibi look\": after each round, decide whether the notes answer the request or which read-only commands come next.",
                         builtIn: ChatEngine.nextInstructions, schema: ChatEngine.nextSchema(["command"]),
                         sample: "Request\nwhich app uses the most memory?\n\nWhat the steps found\n- processes by memory: 1234 Safari 12.5% mem"),
        PromptDefinition("chat.next.task", "Let bibi look: task line", group: chat,
                         purpose: "The task line of each look round.", builtIn: ChatEngine.nextTask),
        PromptDefinition("chat.explore", "Work it out: plan", group: chat,
                         purpose: "With \"Work it out\": when no tool fits, plan in plain words what would answer the request.",
                         builtIn: ChatEngine.explorePlanInstructions, schema: ChatEngine.explorePlanSchema,
                         sample: "User\nwhat happened on this Mac while I was away?"),
        PromptDefinition("chat.explore.command", "Work it out: command", group: chat,
                         purpose: "Turns one planned step into one command.", builtIn: ChatEngine.exploreCommandInstructions,
                         schema: ChatEngine.exploreCommandSchema, sample: "Request: what crashed today?\nStep: list crash reports from the last day"),
        PromptDefinition("chat.explore.repair", "Work it out: retry", group: chat,
                         purpose: "Added after a refused command, with the reason.", builtIn: ChatEngine.exploreRepair),

        PromptDefinition("learn.draft", "Name a learned skill", group: learning,
                         purpose: "When the same request keeps coming back, names the skill bibi proposes to save.",
                         builtIn: SkillMiner.draftInstructions, schema: SkillMiner.draftSchema,
                         sample: "Requests:\n- how much space is free\n- free disk space?\n- disk space left\nSteps:\n- command df -h /"),
        PromptDefinition("learn.create", "Write a skill from a description", group: learning,
                         purpose: "\"Describe a new skill\": drafts a skill's steps from your description.",
                         builtIn: SkillAuthor.instructions, schema: SkillAuthor.schema(["command"]),
                         sample: "show the size of a folder I name"),
        PromptDefinition("learned.summary", "Summarize a learned skill's run", group: learning,
                         purpose: "Summarizes what a learned skill's commands found.", builtIn: GraphSkill.summaryInstructions,
                         schema: GraphSkill.summarySchema, sample: "Request: check free disk space\n$ df -h /\n/dev/disk3s1s1 494Gi 10Gi 112Gi 9% /"),

        PromptDefinition("explain", "Explain a finding", group: analysis,
                         purpose: "Skills ask the model to explain each finding from its observations.",
                         builtIn: Explainer.explainInstructions, schema: Explainer.explainSchema,
                         sample: "Finding: Low free disk space (severity high)\nRule says: 6% of the startup disk is free.\nObservations:\no1: df: 30Gi of 494Gi available"),
        PromptDefinition("correlate", "Link findings into causes", group: analysis,
                         purpose: "Groups a skill's findings into likely causes.", builtIn: Explainer.correlateInstructions,
                         schema: Explainer.correlateSchema,
                         sample: "Findings:\nf1 [high] Memory pressure is high — o1 vm_stat: 2% free\nf2 [medium] Swap use is 9 GB — o2 sysctl vm.swapusage"),
    ]

    /// The per-skill guidance prompt: shown with the skill in the tool list, and where skip reasons are added.
    public static func guidance(_ skill: String, help: String) -> PromptDefinition {
        PromptDefinition("skill." + skill, skill, group: guidance,
                         purpose: skill == "generic" ? "Appended to the chat instructions for every turn." :
                             "Describes \(skill) in the tool list. bibi adds \"Avoid:\" lines here when you skip its proposals and say why.",
                         builtIn: help)
    }
}
