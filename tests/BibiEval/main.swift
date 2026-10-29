import Foundation

// Measures chat against the real on-device model: `swift run bibi-eval` (make eval). Nothing here touches the
// real ~/Library/Application Support/bibi: skills, seeds and app catalog are synced into a scratch home.
setenv("BIBI_HOME", NSTemporaryDirectory() + "bibi-eval-" + UUID().uuidString, 1)

let options = EvalOptions(Array(CommandLine.arguments.dropFirst()))
exit(await Eval(options).run())
