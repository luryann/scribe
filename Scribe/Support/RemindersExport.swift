import EventKit
import Foundation

/// Pushes Scribe's extracted action items into Apple Reminders. On-device, no accounts.
enum RemindersExport {

    enum ExportError: LocalizedError {
        case denied
        case restricted
        case promptFailed(String)
        case noList
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                "Scribe was denied access to Reminders. Turn it on in System Settings › Privacy & Security › Reminders, then try again."
            case .restricted:
                "Reminders access is restricted on this Mac (parental controls or an MDM profile)."
            case .promptFailed(let why):
                "Couldn't ask for Reminders access: \(why)"
            case .noList:
                "No Reminders list is available to add to. Open Reminders and make sure at least one list exists."
            case .failed(let why):
                "Couldn't add to Reminders: \(why)"
            }
        }
    }

    /// Adds every not-done to-do as a reminder. Returns how many were added.
    @discardableResult
    static func add(_ todos: [TodoItem], lecture: String) async throws -> Int {
        try await ensureAccess()

        // Build the working store *after* access is granted: a store created before the grant
        // can hold an empty source list, which makes every calendar lookup below return nil.
        let store = EKEventStore()

        guard let list = writableRemindersCalendar(in: store) else { throw ExportError.noList }

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

    /// Requests full Reminders access, distinguishing "user must go to Settings" from "the
    /// prompt itself failed" so the caller can show something actionable. On the first run the
    /// system permission dialog is shown here.
    private static func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .denied:
            throw ExportError.denied
        case .restricted:
            throw ExportError.restricted
        default:
            // `.notDetermined` (prompt) or `.writeOnly` (insufficient) — ask for full access.
            break
        }

        let requester = EKEventStore()
        let granted: Bool
        do {
            granted = try await requester.requestFullAccessToReminders()
        } catch {
            throw ExportError.promptFailed(error.localizedDescription)
        }
        withExtendedLifetime(requester) {}
        guard granted else { throw ExportError.denied }
    }

    /// The default new-reminder list, or the first list we're allowed to add to.
    private static func writableRemindersCalendar(in store: EKEventStore) -> EKCalendar? {
        if let def = store.defaultCalendarForNewReminders(), def.allowsContentModifications {
            return def
        }
        return store.calendars(for: .reminder).first { $0.allowsContentModifications }
    }
}
