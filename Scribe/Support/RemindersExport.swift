import EventKit
import Foundation

/// Pushes Scribe's extracted action items into Apple Reminders. On-device, no accounts.
enum RemindersExport {

    enum ExportError: LocalizedError {
        case accessDenied
        case noList
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Scribe doesn't have access to Reminders. Turn it on in System Settings › Privacy & Security › Reminders."
            case .noList:       "Couldn't find a Reminders list to add to."
            case .failed(let why): "Couldn't add to Reminders: \(why)"
            }
        }
    }

    /// Adds every not-done to-do as a reminder. Returns how many were added.
    @discardableResult
    static func add(_ todos: [TodoItem], lecture: String) async throws -> Int {
        let store = EKEventStore()

        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { throw ExportError.accessDenied }

        guard let list = store.defaultCalendarForNewReminders() else { throw ExportError.noList }

        var added = 0
        for todo in todos where !todo.isDone {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = todo.text

            var noteLines = ["From lecture: \(lecture)"]
            if let due = todo.dueHint { noteLines.append(due) }
            if let quote = todo.sourceQuote { noteLines.append("“\(quote)”") }
            reminder.notes = noteLines.joined(separator: "\n")

            do {
                try store.save(reminder, commit: false)
                added += 1
            } catch {
                throw ExportError.failed(error.localizedDescription)
            }
        }

        if added > 0 {
            do { try store.commit() }
            catch { throw ExportError.failed(error.localizedDescription) }
        }
        return added
    }
}
