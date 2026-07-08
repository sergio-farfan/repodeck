import RepoDeckKit
import SwiftUI

struct RepoRowView: View {
    let vm: RepoViewModel

    var body: some View {
        Label(vm.repo.name, systemImage: "folder")
            .tag(vm.id)
    }
}
