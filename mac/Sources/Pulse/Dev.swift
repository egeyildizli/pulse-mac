import Foundation

let devArgs: [String] = {
    #if PULSE_DEV
    return CommandLine.arguments
    #else
    return []
    #endif
}()
