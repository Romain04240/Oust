import OustCore

extension AppModel {
    /// Le menu et son raccourci gardent la section et l’état de recherche du
    /// clic, même si la navigation change avant l’exécution de la tâche.
    public func performAnalysisCommand(from section: AppSection, isSearching: Bool) async {
        await performAnalysisCommand(from: section, isSearching: isSearching,
                                     overview: { await self.analyzeOverview() },
                                     manual: { await self.analyze() })
    }

    /// Les tests branchent les mêmes collectes sur leurs fichiers fictifs,
    /// pour observer le panier sans lancer les chercheurs sur le Mac du test.
    func performAnalysisCommand(from section: AppSection, isSearching: Bool,
                                overview: @MainActor () async -> Void,
                                manual: @MainActor () async -> Void) async {
        if section == .overview && !isSearching { await overview() } else { await manual() }
    }
}
