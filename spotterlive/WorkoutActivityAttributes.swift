import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var entryID: String?
        var exerciseName: String
        var timerStart: Date
        var recommendations: String
    }
    var workoutID: String

    static func logURL(workoutID: String, entryID: String?) -> URL {
        var components = URLComponents()
        components.scheme = "spotter"
        components.host = "log-set"
        components.queryItems = [URLQueryItem(name: "workout", value: workoutID), URLQueryItem(name: "entry", value: entryID)]
        return components.url!
    }
}
