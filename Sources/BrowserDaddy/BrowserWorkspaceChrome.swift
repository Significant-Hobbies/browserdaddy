import SwiftUI
import SaaSMakerUI

/// The approved desktop composition. Product state and destinations stay in RootView.
struct BrowserWorkspaceChrome<Content: View, Footer: View>: View {
    @EnvironmentObject private var model: AppModel
    @Binding var workspace: Workspace
    private let reviewOnly: Bool
    private let content: Content
    private let footer: Footer

    init(workspace: Binding<Workspace>, reviewOnly: Bool = false, @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        _workspace = workspace
        self.reviewOnly = reviewOnly
        self.content = content(); self.footer = footer()
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SMWorkspaceSidebar(width: 198) {
                        HStack(spacing: 9) {
                            DaddyArtwork(brand: true).frame(width: 29, height: 32)
                            Text("browserdaddy")
                                .font(.custom(BrowserTheme.palette.displayFont, size: 17).weight(.semibold))
                                .tracking(-0.45)
                        }
                    } navigation: {
                        ForEach([Workspace.blocking, .attention, .tabs, .history, .dashboard]) { destination in
                            navigation(destination)
                        }
                        Text("TOOLS")
                            .font(.system(size: 10, weight: .medium)).tracking(1.1)
                            .foregroundStyle(BrowserTheme.secondaryInk)
                            .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 5)
                        navigation(.router)
                        navigation(.permissions)
                    } footer: {
                        VStack(alignment: .leading, spacing: 16) {
                            if geometry.size.height >= 680 {
                                DaddyArtwork().frame(width: 145, height: 110)
                                    .frame(maxWidth: .infinity)
                            }
                            Button { model.showAbout = true } label: {
                                Label("Local archive", systemImage: "lock")
                                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                            }.buttonStyle(.plain).help("About BrowserDaddy").disabled(reviewOnly)
                        }.padding(.horizontal, 8)
                    }
                    VStack(spacing: 0) {
                        SMWorkspaceScopeBar(workspace.rawValue, systemImage: workspace.icon,
                                            detail: scopeDetail) {
                            if workspace != .blocking {
                                Button { model.runExtract() } label: {
                                    Label(model.extracting ? "Syncing…" : "Sync history", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(SMMacButtonStyle(.quiet))
                                .disabled(model.extracting || reviewOnly)
                            }
                        }
                        content.disabled(reviewOnly).allowsHitTesting(!reviewOnly)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Rectangle().fill(BrowserTheme.divider).frame(height: 1)
                footer.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(BrowserTheme.palette.background)
        .background(SMWorkspaceWindowChrome())
        .containerBackground(BrowserTheme.palette.background, for: .window)
    }

    private func navigation(_ destination: Workspace) -> some View {
        SMWorkspaceNavigationItem(destination.rawValue, systemImage: destination.icon,
                                  isSelected: workspace == destination) { workspace = destination }
    }

    private var scopeDetail: String {
        switch workspace {
        case .blocking: "Site and category rules"
        case .attention: "Measured focus time"
        case .tabs: "Regular browser windows"
        case .history, .dashboard: "Archive on this Mac"
        case .router: "Browser destinations"
        case .permissions: "Access, collection and privacy"
        }
    }
}
