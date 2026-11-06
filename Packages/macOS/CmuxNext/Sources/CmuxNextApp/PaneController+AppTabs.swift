import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPullRequestDiff
import CmuxNextWakeups

extension PaneController {
    /// An app tab (`app-screens-v1`): the app's own page, mounted through the
    /// app supervisor, as a store page tab. Nil while the app has no page here
    /// (not installed, hidden, or the supervisor is unreachable).
    func appTabContent(_ tab: TabModel) -> TabContent? {
        guard let app = tab.appTab,
              let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false) else { return nil }
        return services.pages.view(forStoreTab: tab, page: provider.page, in: daemon.store,
                                   window: state.flatMap { services.windows.controller(for: $0.id) })
            .map(TabContent.page)
    }

    /// A tab of the GitHub page cmux no longer has (removed in cmux#37219; Leo, 2026-11-06: "stop doing
    /// our own renderer for this"), restored from a session saved before: once shown, it becomes its
    /// pull request's github.com page in a browser tab here, and the old tab closes. Nil content meanwhile.
    func replaceRetiredGitHubTab(_ tab: TabModel) -> TabContent? {
        guard services.pages.retiringTabs.insert(tab.id).inserted else { return nil }
        let url = GitHubLink(pageRoute: tab.pageRoute)?.url, id = tab.id, surface = tab.surface
        // After the frame: the show that asked for this tab's content never opens or closes tabs in its turn.
        AfterFrameCommit().run { [weak self] in
            guard let self else { return }
            if let url { newBrowserTab(url: url, opener: surface) }
            close([StripTabID(id)])
        }
        return nil
    }
}
