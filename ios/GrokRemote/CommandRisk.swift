import SwiftUI

/// Reads the command on an approval card and says, in one line, why it deserves a
/// second look.
///
/// The whole point of this app is that nothing runs until you tap — but the tap
/// happens on a phone, often one-handed, often away from the desk, and every card
/// looks the same. `rm -rf build` and `rm -rf ~` are one character apart. This does
/// not block anything and does not decide anything: it labels.
struct CommandRisk {
    enum Level {
        /// Destroys data, rewrites history, or runs as another user.
        case destructive
        /// Leaves the machine, or touches credentials.
        case sensitive
    }

    let level: Level
    /// Short, specific, and about *this* command — not a generic warning.
    let reason: LocalizedStringResource

    var label: LocalizedStringResource {
        level == .destructive ? "DESTRUCTIVE" : "CHECK THIS"
    }
    var icon: String {
        level == .destructive ? "exclamationmark.octagon.fill" : "eye.trianglebadge.exclamationmark.fill"
    }

    /// The most serious thing this command does, or nil when it is unremarkable.
    /// Destructive patterns are tested first, so `sudo rm -rf` reports the deletion.
    static func assess(_ raw: String) -> CommandRisk? {
        let text = raw.lowercased()
        guard !text.isEmpty else { return nil }

        // A couple of flags only mean what they mean in their own case: `-D` force
        // deletes a branch, `-d` refuses when it is unmerged. Checked before the text
        // is folded to lower case.
        for (pattern, reason) in caseSensitive where raw.contains(pattern) {
            return CommandRisk(level: .destructive, reason: reason)
        }
        for (pattern, reason) in destructive where matches(pattern, in: text) {
            return CommandRisk(level: .destructive, reason: reason)
        }
        for (pattern, reason) in sensitive where matches(pattern, in: text) {
            return CommandRisk(level: .sensitive, reason: reason)
        }
        return nil
    }

    /// Word-boundary-aware contains. A bare `contains("rm ")` fires on "confirm ",
    /// and a card that cries wolf is a card people stop reading.
    private static func matches(_ needle: String, in haystack: String) -> Bool {
        guard let range = haystack.range(of: needle) else { return false }
        guard let first = needle.first, first.isLetter || first.isNumber else { return true }
        if range.lowerBound == haystack.startIndex { return true }
        let before = haystack[haystack.index(before: range.lowerBound)]
        // A shell command can start after a pipe, a semicolon, && or a newline.
        return !(before.isLetter || before.isNumber || before == "-" || before == "_" || before == "/" || before == ".")
    }

    private static let caseSensitive: [(String, LocalizedStringResource)] = [
        ("git branch -D", "Deletes a branch that may not be merged anywhere."),
        ("git branch --delete --force", "Deletes a branch that may not be merged anywhere."),
    ]

    // Ordered most-specific first: the first hit is what the card says.
    private static let destructive: [(String, LocalizedStringResource)] = [
        ("rm -rf /",        "Deletes a directory tree recursively, with no prompt."),
        ("rm -fr",          "Deletes a directory tree recursively, with no prompt."),
        ("rm -rf",          "Deletes a directory tree recursively, with no prompt."),
        ("rm -r",           "Deletes a directory and everything under it."),
        ("rm -f",           "Deletes files without asking."),
        ("git push --force","Overwrites the remote branch; anything only on the remote is lost."),
        ("git push -f",     "Overwrites the remote branch; anything only on the remote is lost."),
        ("git reset --hard","Throws away uncommitted work in the tree."),
        ("git clean -fd",   "Deletes untracked files and directories."),
        ("git checkout -- .", "Reverts every modified file in the tree."),
        ("sudo ",           "Runs as the administrator, outside the project's reach."),
        ("mkfs",            "Formats a filesystem."),
        ("dd if=",          "Writes raw blocks; a wrong target overwrites a disk."),
        ("diskutil erase",  "Erases a disk."),
        ("> /dev/",         "Writes straight to a device node."),
        (":(){",            "Fork bomb: this is a denial-of-service against your own machine."),
        ("chmod 777",       "Makes files writable by every account on the machine."),
        ("chown -r",        "Reassigns ownership of a whole tree."),
        ("drop table",      "Deletes a database table and its rows."),
        ("drop database",   "Deletes an entire database."),
        ("truncate table",  "Empties a database table."),
        ("delete from",     "Deletes rows from a database table."),
        ("killall",         "Force-quits every process with that name."),
        ("pkill",           "Force-quits matching processes."),
        ("shutdown",        "Shuts down or restarts the machine."),
        ("defaults delete", "Removes an app's stored preferences."),
        ("npm unpublish",   "Removes a package version other people may depend on."),
        ("history -c",      "Erases your shell history."),
    ]

    private static let sensitive: [(String, LocalizedStringResource)] = [
        ("| sh",            "Pipes something downloaded from the network straight into a shell."),
        ("| bash",          "Pipes something downloaded from the network straight into a shell."),
        ("|sh",             "Pipes something downloaded from the network straight into a shell."),
        ("|bash",           "Pipes something downloaded from the network straight into a shell."),
        (".ssh",            "Reads or writes your SSH keys."),
        ("id_rsa",          "Touches a private SSH key."),
        (".aws",            "Touches your cloud credentials."),
        (".netrc",          "Touches stored login credentials."),
        (".npmrc",          "Touches your npm credentials."),
        ("keychain",        "Touches the system keychain."),
        (".env",            "Reads or writes a secrets file."),
        ("credentials",     "Touches a credentials file."),
        ("security find",   "Reads secrets out of the keychain."),
        ("git push",        "Publishes commits to the remote."),
        ("npm publish",     "Publishes a package publicly."),
        ("gh release",      "Publishes a release."),
        ("scp ",            "Copies files to another machine."),
        ("ssh ",            "Opens a session on another machine."),
        ("curl ",           "Talks to the network."),
        ("wget ",           "Downloads from the network."),
        ("--privileged",    "Runs a container with the host's privileges."),
    ]
}
