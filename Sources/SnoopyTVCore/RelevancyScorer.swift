import Foundation

public struct RelevancyScorer: Sendable {
    public struct ScoredAsset: Sendable {
        public let asset: AssetRecord
        public let score: Int
    }

    public init() {}

    public func score(_ asset: AssetRecord, context: SelectionContext, memory: SelectionMemory) -> Int? {
        relevanceScore(asset, context: context).map { $0 - recencyPenalty(asset, memory: memory) }
    }

    /// Returns authored contextual relevance without mixing in playback
    /// history. Callers that own separate media pools can apply pool-local
    /// recency while retaining ordinary generic assets in the weighted draw.
    public func relevanceScore(_ asset: AssetRecord, context: SelectionContext) -> Int? {
        guard asset.integrity?.valid != false else { return nil }
        guard dependenciesMatch(asset, context: context) else { return nil }
        guard exclusionsMatch(asset, context: context) else { return nil }
        guard let relevancy = asset.relevancyData?.objectValue else { return 0 }

        var score = 0
        if case .array(let info) = relevancy["info"] {
            // Empty info is the model's generic/default candidate, not an
            // impossible condition. tvOS keeps these in the selection pool
            // and boosts matching non-empty entries above them.
            if info.isEmpty {
                score += dependencyBoost(asset, context: context)
                return score
            }
            guard let familyScore = matchedFamilyScore(info, context: context) else { return nil }
            score = familyScore
        }
        score += dependencyBoost(asset, context: context)
        return score
    }

    /// Evaluates an authored `info` list. Clauses are grouped by condition
    /// family (timeOfDay, weather, calendar, routine, hourlyEvent): within a
    /// family any clause may match (OR), and every family present must match
    /// (AND). Apple's own asset names prove this reading: `ScenePalette_Cloudy_Day`
    /// lists {cloudy} and {morning, afternoon}; the moon visitors list
    /// {evening, lateNight} and one lunar phase; `ClockWipeExcludeLateNightBadWeather`
    /// lists three times of day and five fair-weather conditions. Treating the
    /// whole list as OR made every palette eligible on any day and put a full
    /// moon in the afternoon sky. Returns the summed family specificity, or nil
    /// when any family has no matching clause.
    func matchedFamilyScore(_ info: [JSONValue], context: SelectionContext) -> Int? {
        var order: [String] = []
        var matched: [String: Bool] = [:]
        var weights: [String: Int] = [:]
        for candidate in info {
            guard let clauses = candidate.objectValue, !clauses.isEmpty else { continue }
            let family = clauses.keys.sorted().joined(separator: "+")
            if matched[family] == nil {
                order.append(family)
                matched[family] = false
                weights[family] = specificity(clauses)
            }
            if matches(clauses, context: context) { matched[family] = true }
        }
        guard !order.isEmpty else { return nil }
        var total = 0
        for family in order {
            guard matched[family] == true else { return nil }
            total += weights[family] ?? 0
        }
        return total
    }

    private func matches(_ clauses: [String: JSONValue], context: SelectionContext) -> Bool {
        clauses.allSatisfy { key, value in
            guard let object = value.objectValue else { return true }
            return object.allSatisfy { field, expected in
                let expectedValues = tokens(in: expected, fallbackKey: field)
                switch key {
                // IdleCharacterCore represents lunar phase visitors as
                // RelevancyWeatherCondition values (moonFull, moonFirstQuarter,
                // and so on), although our context keeps ephemeris separate
                // from current atmospheric weather.
                case "weather":
                    return !(context.weatherConditions.union(context.moonPhases)).isDisjoint(with: expectedValues)
                case "timeOfDay": return context.timeOfDay.map(expectedValues.contains) ?? false
                case "routine":
                    var routines = context.routineConditions
                    if let routine = context.routine { routines.insert(routine) }
                    return !routines.isDisjoint(with: expectedValues)
                case "calendar": return !context.calendarEvents.isDisjoint(with: expectedValues)
                case "hourlyEvent": return !context.hourlyEvents.isDisjoint(with: expectedValues)
                case "moonPhase", "moon": return !context.moonPhases.isDisjoint(with: expectedValues)
                default: return true
                }
            }
        }
    }

    private func tokens(in value: JSONValue, fallbackKey: String) -> Set<String> {
        switch value {
        case .string(let value): return [value]
        case .array(let values): return Set(values.flatMap { tokens(in: $0, fallbackKey: fallbackKey) })
        case .object(let object):
            if object.isEmpty { return [fallbackKey] }
            return Set(object.flatMap { key, value in
                let nested = tokens(in: value, fallbackKey: key)
                return nested.isEmpty ? [key] : Array(nested)
            })
        default: return []
        }
    }

    private func specificity(_ clauses: [String: JSONValue]) -> Int {
        clauses.reduce(0) { partial, item in
            let weight: Int
            switch item.key { case "calendar": weight = 80; case "hourlyEvent": weight = 65; case "weather", "moonPhase", "moon": weight = 50; case "timeOfDay": weight = 30; case "routine": weight = 25; default: weight = 10 }
            return partial + weight
        }
    }

    private func dependenciesMatch(_ asset: AssetRecord, context: SelectionContext) -> Bool {
        guard let values = asset.relevancyData?.objectValue?["dependencies"], case .array(let dependencies) = values else { return true }
        return dependencies.allSatisfy { dependency in
            if let name = dependency.stringValue { return context.fulfilledDependencies.contains(name) }
            guard let object = dependency.objectValue else { return true }
            if let category = object["category"]?.stringValue,
               !context.activeCategories.contains(category) {
                return false
            }
            if case .array(let infos) = object["info"], !infos.isEmpty {
                return matchedFamilyScore(infos, context: context) != nil
            }
            return true
        }
    }

    private func exclusionsMatch(_ asset: AssetRecord, context: SelectionContext) -> Bool {
        guard let values = asset.relevancyData?.objectValue?["exclusions"], case .array(let exclusions) = values else { return true }
        return exclusions.allSatisfy { exclusion in
            if let name = exclusion.stringValue { return !context.excludedValues.contains(name) }
            guard let object = exclusion.objectValue else { return true }
            // An exclusion object is conjunctive. For example, an action
            // excluded by `sceneFullscreenEffectVisitor` in windy weather is
            // still valid on a windy day when no full-screen visitor is
            // active. Treating the weather clause alone as an exclusion
            // removes a large part of Apple's authored action graph.
            if let category = object["category"]?.stringValue,
               !context.activeCategories.contains(category) {
                return true
            }
            if case .array(let infos) = object["info"], !infos.isEmpty {
                return matchedFamilyScore(infos, context: context) == nil
            }
            return object["category"]?.stringValue == nil
        }
    }

    private func dependencyBoost(_ asset: AssetRecord, context: SelectionContext) -> Int {
        guard let values = asset.relevancyData?.objectValue?["dependencies"], case .array(let dependencies) = values else { return 0 }
        return dependencies.reduce(0) { partial, item in
            if let name = item.stringValue, context.fulfilledDependencies.contains(name) { return partial + 15 }
            if let object = item.objectValue {
                let categoryMatches = object["category"]?.stringValue
                    .map(context.activeCategories.contains) ?? true
                let infoMatches: Bool
                if case .array(let infos) = object["info"], !infos.isEmpty {
                    infoMatches = infos.contains { info in
                        guard let clauses = info.objectValue else { return false }
                        return matches(clauses, context: context)
                    }
                } else {
                    infoMatches = true
                }
                if categoryMatches && infoMatches { return partial + 15 }
            }
            return partial
        }
    }

    private func recencyPenalty(_ asset: AssetRecord, memory: SelectionMemory) -> Int {
        if memory.lastSelectedID == asset.id { return 100 }
        if let index = memory.recentIDs.firstIndex(of: asset.id) { return max(5, 40 - index * 5) }
        return min(memory.playCounts[asset.id, default: 0], 15)
    }
}
