import SwiftUI

@main
struct SpotterApp: App {
    @State private var store = Store()
    @State private var nearby = NearbySync()
    @State private var cloud = CloudSync()
    @State private var chatGPT = ChatGPTConnection()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store).environment(nearby).environment(cloud).environment(chatGPT)
                .tint(.indigo)
                .onAppear {
                    nearby.store = store; cloud.store = store
                    store.didChange = { nearby.send() }
                }
        }
    }
}
