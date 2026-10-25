import ControlClient
import Foundation

// `mynotion` — тонкий клиент MyNotion (R8): разбор по каталогу, запуск приложения в фоне, JSON в stdout.
let status = MyNotionCLI.run(Array(CommandLine.arguments.dropFirst()),
                             out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                             err: { FileHandle.standardError.write(Data($0.utf8)) })
exit(status)
