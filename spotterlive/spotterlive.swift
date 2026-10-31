import ActivityKit
import WidgetKit
import SwiftUI

struct spotterlive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityContent(state: context.state, destination: url(context))
                .padding(16)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(url(context))
        } dynamicIsland: { context in
            DynamicIsland {
                // A single full-width region keeps the two rows together. Separate
                // leading/trailing regions constrain titles around the camera.
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutActivityContent(state: context.state, destination: url(context))
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }
            } compactLeading: {
                Text(context.state.entryID == nil ? "Workout" : context.state.exerciseName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 100, alignment: .leading)
            } compactTrailing: {
                WorkoutActivityTimer(start: context.state.timerStart, compact: true)
            } minimal: {
                Image(systemName: "dumbbell.fill")
            }
            .widgetURL(url(context))
        }
    }

    private func url(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> URL {
        WorkoutActivityAttributes.logURL(workoutID: context.attributes.workoutID, entryID: context.state.entryID)
    }
}

private struct WorkoutActivityContent: View {
    let state: WorkoutActivityAttributes.ContentState
    let destination: URL
    private var hasExercise: Bool { state.entryID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(hasExercise ? state.exerciseName : "Workout in progress")
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("REST").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    WorkoutActivityTimer(start: state.timerStart)
                }
            }
            HStack(spacing: 12) {
                Text(hasExercise ? state.recommendations : "Choose your next exercise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Link(destination: destination) {
                    Text(hasExercise ? "Log set" : "Open workout")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(.indigo, in: Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkoutActivityTimer: View {
    let start: Date
    var compact = false

    var body: some View {
        // Timer text needs a finite proposal; intrinsic/fixed sizing can consume
        // the Island's available width and push the other content offscreen.
        Text(start, style: .timer)
            .font(compact ? .caption.monospacedDigit() : .headline.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: compact ? 62 : 88, alignment: .trailing)
            .accessibilityLabel("Time since last set or session start")
    }
}

#Preview("Between exercises", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes(workoutID: "preview")) {
    spotterlive()
} contentStates: {
    WorkoutActivityAttributes.ContentState(entryID: nil, exerciseName: "Choose an exercise", timerStart: .now.addingTimeInterval(-125), recommendations: "Choose an exercise")
}

#Preview("Exercise", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes(workoutID: "preview")) {
    spotterlive()
} contentStates: {
    WorkoutActivityAttributes.ContentState(entryID: "exercise", exerciseName: "Incline dumbbell bench press", timerStart: .now.addingTimeInterval(-75), recommendations: "8–12 reps · 2 RIR · 3 sets")
}
