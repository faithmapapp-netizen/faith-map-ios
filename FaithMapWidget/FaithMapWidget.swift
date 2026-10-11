import WidgetKit
import SwiftUI

struct VerseEntry: TimelineEntry {
    let date: Date
    let text: String
    let reference: String
}

struct VerseProvider: TimelineProvider {
    func placeholder(in context: Context) -> VerseEntry {
        VerseEntry(date: Date(), text: "Be still, and know that I am God.", reference: "Psalms 46:10")
    }

    func getSnapshot(in context: Context, completion: @escaping (VerseEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VerseEntry>) -> Void) {
        fetchVerse { entry in
            // Refresh at midnight for the next day's verse
            let calendar = Calendar.current
            let nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date())!)
            let timeline = Timeline(entries: [entry], policy: .after(nextMidnight))
            completion(timeline)
        }
    }

    private func fetchVerse(completion: @escaping (VerseEntry) -> Void) {
        guard let url = URL(string: "https://havenmedia.app/api/push/verse") else {
            completion(placeholder(in: Context.self as! Context))
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var text = "Be still, and know that I am God."
            var reference = "Psalms 46:10"
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = json["text"] as? String { text = t }
                if let r = json["reference"] as? String { reference = r }
                // Fallback: construct from book/chapter/verse
                if json["reference"] == nil,
                   let book = json["book"] as? String,
                   let ch = json["chapter"] as? Int,
                   let v = json["verse"] as? Int {
                    reference = "\(book) \(ch):\(v)"
                }
            }
            completion(VerseEntry(date: Date(), text: text, reference: reference))
        }.resume()
    }
}

struct VerseWidgetEntryView: View {
    var entry: VerseEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Prayer")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .lineLimit(3)
                Text(entry.reference)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        case .accessoryInline:
            Text("\(entry.reference): \(entry.text)")
                .lineLimit(1)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                Text("Daily Prayer Verse")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(entry.text)
                    .font(.footnote)
                    .lineLimit(4)
                Spacer()
                Text(entry.reference)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
        case .systemMedium:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Daily Prayer Verse")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(entry.text)
                        .font(.body)
                        .lineLimit(3)
                    Text(entry.reference)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
        default:
            Text(entry.text)
                .padding()
        }
    }
}

@main
struct FaithMapWidget: Widget {
    let kind: String = "FaithMapWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VerseProvider()) { entry in
            VerseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Daily Prayer Verse")
        .description("See today's prayer verse on your Home or Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall, .systemMedium])
    }
}
