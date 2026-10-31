import ActivityKit

@MainActor
final class WorkoutLiveActivity {
    // Serialize updates so an older update cannot overwrite a newer exercise/set.
    private var pending: Task<Void, Never>?

    func update(_ snapshot: WorkoutActivitySnapshot?) {
        let previous = pending
        pending = Task {
            await previous?.value
            for activity in Activity<WorkoutActivityAttributes>.activities where activity.attributes.workoutID != snapshot?.workoutID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            guard let snapshot else { return }
            let state = WorkoutActivityAttributes.ContentState(entryID: snapshot.entryID,
                exerciseName: snapshot.exerciseName, timerStart: snapshot.timerStart, recommendations: snapshot.recommendations)
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity = Activity<WorkoutActivityAttributes>.activities.first(where: { $0.attributes.workoutID == snapshot.workoutID }) {
                await activity.update(content)
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity.request(attributes: WorkoutActivityAttributes(workoutID: snapshot.workoutID), content: content, pushType: nil)
                } catch {
                    // Workout logging remains available when the system declines a Live Activity.
                }
            }
        }
    }
}
