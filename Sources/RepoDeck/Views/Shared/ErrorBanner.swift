import RepoDeckCore
import SwiftUI

struct ErrorBanner: View {
    let vm: RepoViewModel

    var body: some View {
        if let error = vm.actionError {
            RepositoryFailureBanner(vm: vm, failure: OperationFailure(error)) {
                vm.actionError = nil
            }
        }
    }
}
