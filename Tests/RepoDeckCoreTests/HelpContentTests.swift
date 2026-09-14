import Testing
@testable import RepoDeckCore

@Suite struct HelpContentTests {
    @Test func everyStableDestinationHasCompleteContentAndValidRelatedTopics() {
        #expect(Set(HelpContent.articles.map(\.id)) == Set(HelpTopicID.allCases))
        #expect(HelpContent.articles.count == HelpTopicID.allCases.count)
        for article in HelpContent.articles {
            #expect(!article.title.isEmpty)
            #expect(!article.summary.isEmpty)
            #expect(!article.sections.isEmpty)
            #expect(article.sections.allSatisfy { !$0.title.isEmpty && (!$0.paragraphs.isEmpty || !$0.steps.isEmpty) })
            #expect(article.related.allSatisfy { $0 != article.id && HelpContent.article($0) != nil })
        }
    }

    @Test func emptyOrPunctuationOnlySearchKeepsCuratedOrder() {
        #expect(HelpContent.search(" \n ").map(\.id) == HelpContent.articles.map(\.id))
        #expect(HelpContent.search("?!").map(\.id) == HelpContent.articles.map(\.id))
    }

    @Test func searchMatchesCaseAccentsAndWordsAcrossFields() {
        #expect(HelpContent.search("RÉBASE conflict").first?.id == .conflicts)
        #expect(HelpContent.search("GitLab expired").first?.id == .reviewTroubleshooting)
        #expect(HelpContent.search("permission-denied").contains { $0.id == .gitTroubleshooting })
    }

    @Test func errorCodesAndWorkflowAliasesFindRelevantRecovery() {
        #expect(HelpContent.search("403").map(\.id) == [.reviewTroubleshooting])
        #expect(HelpContent.search("work tree").contains { $0.id == .branchesAndWorktrees })
        #expect(HelpContent.search("partial list").first?.id == .refreshTroubleshooting)
        #expect(HelpContent.search("keyboard shortcuts").first?.id == .keyboard)
    }

    @Test func everyTermMustMatchAndUnknownQueriesReturnNoResults() {
        #expect(HelpContent.search("GitLab extraterrestrial").isEmpty)
        #expect(HelpContent.search("no-such-help-topic-9274").isEmpty)
    }
}
