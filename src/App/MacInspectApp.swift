import SwiftUI

@main
struct MacInspectApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.automatic)
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.t("menu.about", AppBrand.name)) {
                    AppAbout.show()
                }
            }
        }
    }
}
