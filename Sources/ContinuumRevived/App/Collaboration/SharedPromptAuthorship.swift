import Foundation

/// The words for who sent a shared agent's last prompt, the same on the
/// owner's tile and on a teammate's view of it.
enum SharedPromptAuthorship {
    static func label(mine: Bool, name: String?, at: Date) -> String {
        if mine { return "You sent the last prompt" }
        let time = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
        return "\(name ?? "A teammate") sent the last prompt · \(time)"
    }
}
