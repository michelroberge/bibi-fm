import BibiCore
import BibiSkills
import BibiWeb
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
// Commands that can reach Contacts, Calendars, Reminders or other apps run as their own responsible process.
if ["ui", "apps"].contains(CommandLine.arguments.dropFirst().first ?? ""), let code = Responsibility.relaunch() {
    exit(code)
}
let code = await CLI().main(Array(CommandLine.arguments.dropFirst()))
exit(code)
