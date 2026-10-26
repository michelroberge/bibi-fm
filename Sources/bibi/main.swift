import BibiCore
import BibiSkills
import BibiWeb
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let code = await CLI().main(Array(CommandLine.arguments.dropFirst()))
exit(code)
