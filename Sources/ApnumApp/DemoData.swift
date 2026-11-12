import ApnumCore
import Foundation

/// Sample content for demo mode (APNUM_DEMO=1), used for screenshots and trying the app.
/// Only writes into an empty data folder.
enum DemoData {
    @MainActor
    static func seedIfEmpty(_ model: AppModel) async {
        guard await model.alarms.alarms().isEmpty, await model.notes.notes().isEmpty else { return }

        let weekdays: JSONValue = ["monday", "tuesday", "wednesday", "thursday", "friday"]
        await model.run("alarm.create", ["hour": 6, "minute": 45, "label": "Wake up", "repeatDays": weekdays, "snoozeMinutes": 9])
        await model.run("alarm.create", ["hour": 8, "minute": 30, "label": "Slow morning", "repeatDays": ["saturday", "sunday"]])
        await model.run("alarm.create", ["hour": 14, "minute": 0, "label": "Take vitamins", "snoozeMinutes": 0])
        await model.run("alarm.create", ["hour": 22, "minute": 45, "label": "Wind down", "repeatDays": [
            "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        ]])
        if let id = await model.run("alarm.create", ["hour": 5, "minute": 30, "label": "Early flight"])?["id"] {
            await model.run("alarm.update", ["id": id, "isEnabled": false])
        }

        await model.run("timer.start", ["minutes": 25, "label": "Focus"])
        if let id = await model.run("timer.start", ["minutes": 4, "label": "Tea"])?["id"] {
            await model.run("timer.pause", ["id": id])
        }

        await model.run("note.create", [
            "title": "Trip to Goa", "pinned": true, "tags": ["travel"],
            "body": "Flights on the 18th, back on the 23rd.\n\n- Book the homestay near Assagao\n- Sunscreen, hat, the good camera\n- Ask Meera about the scooter",
        ])
        await model.run("note.create", [
            "title": "apnum ideas", "pinned": true, "tags": ["apnum", "ideas"],
            "body": "Phone link first, then WhatsApp.\n\nAlarms should sync both ways with the Android companion.",
        ])
        await model.run("note.create", [
            "title": "Reading list", "tags": ["books"],
            "body": "- The Overstory\n- Piranesi\n- A Pattern Language",
        ])
        await model.run("note.create", [
            "title": "Groceries", "tags": ["home"],
            "body": "Oat milk, coffee beans, limes, paneer, curry leaves",
        ])
    }
}
