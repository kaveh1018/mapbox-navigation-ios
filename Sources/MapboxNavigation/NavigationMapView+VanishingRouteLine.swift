import CoreLocation
import UIKit
import MapboxDirections
import MapboxCoreNavigation
import Turf
import MapboxMaps

extension NavigationMapView {

    struct RoutePoints {
        var nestedList: [[[CLLocationCoordinate2D]]]
        var flatList: [CLLocationCoordinate2D]
    }
    
    struct RouteLineGranularDistances {
        var distance: Double
        var distanceArray: [RouteLineDistancesIndex]
    }
    
    struct RouteLineDistancesIndex {
        var point: CLLocationCoordinate2D
        var distanceRemaining: Double
    }
    
    // MARK: - Vanishing route line methods
    
    func initPrimaryRoutePoints(route: Route) {
        routePoints = parseRoutePoints(route: route)
        routeLineGranularDistances = calculateGranularDistances(routePoints?.flatList ?? [])
    }
    
    /**
     Tranform the route data into nested arrays of legs -> steps -> coordinates.
     The first and last point of adjacent steps overlap and are duplicated.
     */
    func parseRoutePoints(route: Route) -> RoutePoints {
        let nestedList = route.legs.map { (routeLeg: RouteLeg) -> [[CLLocationCoordinate2D]] in
            return routeLeg.steps.map { (routeStep: RouteStep) -> [CLLocationCoordinate2D] in
                if let routeShape = routeStep.shape {
                    if !routeShape.coordinates.isEmpty {
                        return routeShape.coordinates
                    } else { return [] }
                } else {
                    return []
                }
            }
        }
        let flatList = nestedList.flatMap { $0.flatMap { $0.compactMap { $0 } } }
        return RoutePoints(nestedList: nestedList, flatList: flatList)
    }
    
    /**
     Find and cache the index of the upcoming [RouteLineDistancesIndex].
     */
    public func updateUpcomingRoutePointIndex(routeProgress: RouteProgress) {
        guard let completeRoutePoints = routePoints else {
            routeRemainingDistancesIndex = nil
            return
        }
        let currentLegProgress = routeProgress.currentLegProgress
        let currentStepProgress = routeProgress.currentLegProgress.currentStepProgress
        /**
         Find the count of remaining points in the current step.
         */
        var allRemainingPoints = getSlicedLinePointsCount(currentLegProgress: currentLegProgress, currentStepProgress: currentStepProgress)
        
        /**
         Add to the count of remaining points all of the remaining points on the current leg, after the current step.
         */
        let currentLegSteps = completeRoutePoints.nestedList[routeProgress.legIndex]
        let startIndex = currentLegProgress.stepIndex + 1
        let endIndex = currentLegSteps.count - 1
        if startIndex < endIndex {
            allRemainingPoints += currentLegSteps.prefix(endIndex).suffix(from: startIndex).flatMap{ $0.compactMap{ $0 } }.count
        }
        
        /**
         Add to the count of remaining points all of the remaining legs.
         */
        for index in stride(from: routeProgress.legIndex + 1, to: completeRoutePoints.nestedList.count, by: 1) {
            allRemainingPoints += completeRoutePoints.nestedList[index].flatMap{ $0 }.count
        }
        
        /**
         After calculating the number of remaining points and the number of all points,  calculate the index of the upcoming point.
         */
        let allPoints = completeRoutePoints.flatList.count
        routeRemainingDistancesIndex = allPoints - allRemainingPoints - 1
    }
    
    func getSlicedLinePointsCount(currentLegProgress: RouteLegProgress, currentStepProgress: RouteStepProgress) -> Int {
        let startDistance = currentStepProgress.distanceTraveled
        let stopDistance = currentStepProgress.step.distance
        
        /**
         Implement the Turf.lineSliceAlong(lineString, startDistance, stopDistance) to return a sliced lineString.
         */
        if let lineString = currentStepProgress.step.shape,
           let midPoint = lineString.coordinateFromStart(distance: startDistance),
           let slicedLine = lineString.trimmed(from: midPoint, distance: stopDistance - startDistance) {
            return slicedLine.coordinates.count - 1
        }
         
        return 0
    }
    
    func calculateGranularDistances(_ coordinates: [CLLocationCoordinate2D]) -> RouteLineGranularDistances? {
        if coordinates.isEmpty { return nil }
        var distance = 0.0
        var indexArray = [RouteLineDistancesIndex?](repeating: nil, count: coordinates.count)
        for index in stride(from: coordinates.count - 1, to: 0, by: -1) {
            let curr = coordinates[index]
            let prev = coordinates[index - 1]
            distance += calculateDistance(coordinate1: curr, coordinate2: prev)
            indexArray[index - 1] = RouteLineDistancesIndex(point: prev, distanceRemaining: distance)
        }
        indexArray[coordinates.count - 1] = RouteLineDistancesIndex(point: coordinates[coordinates.count - 1], distanceRemaining: 0.0)
        return RouteLineGranularDistances(distance: distance, distanceArray: indexArray.compactMap{ $0 })
    }
    
    /**
     Calculates the distance between 2 points using [EPSG:3857 projection](https://epsg.io/3857).
     */
    func calculateDistance(coordinate1: CLLocationCoordinate2D, coordinate2: CLLocationCoordinate2D) -> Double {
        let distanceArray: [Double] = [
            (projectX(coordinate1.longitude) - projectX(coordinate2.longitude)),
            (projectY(coordinate1.latitude) - projectY(coordinate2.latitude))
        ]
        return (distanceArray[0] * distanceArray[0] + distanceArray[1] * distanceArray[1]).squareRoot()
    }

    func projectX(_ x: Double) -> Double {
        return x / 360.0 + 0.5
    }
    
    func projectY(_ y: Double) -> Double {
        let sinValue = sin(y * Double.pi / 180)
        let newYValue = 0.5 - 0.25 * log((1 + sinValue) / (1 - sinValue)) / Double.pi
        if newYValue < 0 {
            return 0.0
        } else if newYValue > 1 {
            return 1.1
        } else {
            return newYValue
        }
    }
    
    /**
     Updates the fractionTraveled along the route line from the origin point to the indicated point.
     
     - parameter coordinate: Current position of the user location.
     */
    func updateFractionTraveled(_ coordinate: CLLocationCoordinate2D?) {
        guard let granularDistances = routeLineGranularDistances,let index = routeRemainingDistancesIndex, let location = coordinate else { return }
        guard index < granularDistances.distanceArray.endIndex else { return }
        let traveledIndex = granularDistances.distanceArray[index]
        let upcomingPoint = traveledIndex.point
        
        /**
         Take the remaining distance from the upcoming point on the route and extends it by the exact position of the puck.
         */
        let remainingDistance = traveledIndex.distanceRemaining + calculateDistance(coordinate1: upcomingPoint, coordinate2: location)
        
        /**
         Calculate the percentage of the route traveled.
         */
        if granularDistances.distance >= remainingDistance {
            let offSet = (1.0 - remainingDistance / granularDistances.distance)
            if offSet >= 0 {
                fractionTraveled = offSet
            }
        }
    }
    
    /**
     Updates the route style layer and its casing style layer to gradually disappear as the user location puck travels along the displayed route.
     
     - parameter coordinate: Current position of the user location.
     - parameter routeProgress: Current route progress.
     */
    public func updateVanishingRouteLine(coordinate: CLLocationCoordinate2D?, routeProgress: RouteProgress) {
        updateFractionTraveled(coordinate)
        
        let mainRouteLayerIdentifier = routeProgress.route.identifier(.route(isMainRoute: true))
        let mainRouteCasingLayerIdentifier = routeProgress.route.identifier(.routeCasing(isMainRoute: true))
        
        if fractionTraveled >= 1.0 {
            // In case if route was fully travelled - remove main route and its casing.
            do {
                try mapView.mapboxMap.style.removeLayer(withId: mainRouteLayerIdentifier)
                try mapView.mapboxMap.style.removeLayer(withId: mainRouteCasingLayerIdentifier)
            } catch {
                print("Failed to remove main route line layer.")
            }
            
            fractionTraveled = 0.0
            return
        }
        
        // Calculate the current route leg congestion features only when it's changed when routeLineTracksTraversal enabled.
        if routeProgress.currentLeg.segmentCongestionLevels != currentLegCongestionLevels {
            currentLegCongestionLevels = routeProgress.currentLeg.segmentCongestionLevels
            let congestionFeatures = routeProgress.route.congestionFeatures(legIndex: currentLegIndex, roadClassesWithOverriddenCongestionLevels: roadClassesWithOverriddenCongestionLevels)
            currentLineGradientStops = routeLineGradient(congestionFeatures, fractionTraveled: fractionTraveled)
        }
        
        if !currentLineGradientStops.isEmpty {
            do {
                try mapView.mapboxMap.style.updateLayer(withId: mainRouteLayerIdentifier) { (lineLayer: inout LineLayer) throws in
                    let mainRouteLayerGradient = self.updateRouteLineGradientStops(fractionTraveled: fractionTraveled, gradientStops: currentLineGradientStops)
                    lineLayer.lineGradient = .expression(Expression.routeLineGradientExpression(mainRouteLayerGradient, lineBaseColor: trafficUnknownColor))
                }
                
                try mapView.mapboxMap.style.updateLayer(withId: mainRouteCasingLayerIdentifier) { (lineLayer: inout LineLayer) throws in
                    let mainRouteCasingLayerGradient = routeLineGradient(fractionTraveled: fractionTraveled)
                    lineLayer.lineGradient = .expression(Expression.routeLineGradientExpression(mainRouteCasingLayerGradient, lineBaseColor: routeCasingColor))
                }
            } catch {
                print("Failed to update main route line layer.")
            }
        }
        
    }
    
    func updateRouteLineGradientStops(fractionTraveled: Double, gradientStops: [Double: UIColor]) -> [Double: UIColor] {
        var filteredGradientStops = gradientStops.filter { key, value in
            return key >= fractionTraveled
        }
        
        let  nextDownFractionTraveled = Double(CGFloat(fractionTraveled).nextDown)
        if let minStop = filteredGradientStops.min(by: { $0.0 < $1.0 }) {
            filteredGradientStops[0.0] = traversedRouteColor
            if nextDownFractionTraveled >= 0.0 {
                filteredGradientStops[nextDownFractionTraveled] = traversedRouteColor
            }
            filteredGradientStops[fractionTraveled] = minStop.value
        }

        return filteredGradientStops
    }
    
    func routeLineGradient(_ congestionFeatures: [Turf.Feature]? = nil, fractionTraveled: Double, isMain: Bool = true) -> [Double: UIColor] {
        var gradientStops = [Double: UIColor]()
        
        if let congestionFeatures = congestionFeatures {
            let routeDistance = congestionFeatures.compactMap({ ($0.geometry.value as? LineString)?.distance() }).reduce(0, +)
            // The route line color for the nextDown of line gradient stops. Defaults as `traversedRouteColor`.
            var previousStopColor = traversedRouteColor
            var legDistanceTraveled = 0.0
            
            for (_, feature) in congestionFeatures.enumerated() {
                // The color for the route line basedon on the value of `CurrentLegAttribute` and the `CongestionAttribute`. Defaults as `routeCasingColor`.
                var associatedFeatureColor = routeCasingColor
                // Each feature in the `congestionFeatures` represents one route leg.
                let lineString = feature.geometry.value as? LineString
                guard let legDistance = lineString?.distance() else { return gradientStops }
                let legFraction = legDistance/routeDistance
                
                if let congestionAttribute = feature.properties?[CongestionAttribute] as? [Double: String],
                   let isCurrentLeg = feature.properties?[CurrentLegAttribute] as? Bool {
                    // When `CurrentLegAttribute` is true, the route leg displays the congestion level. Otherwise, it shows the `routeCasingColor`.
                    if isCurrentLeg {
                        for fractionInLeg in congestionAttribute.keys {
                            let fractionInRoute = fractionInLeg * legFraction
                            let congestionLevel = congestionAttribute[fractionInLeg]
                            associatedFeatureColor = congestionColor(for: congestionLevel, isMain: isMain)
                            
                            let nextDownfractionInRoute = Double(CGFloat(fractionInRoute).nextDown)
                            gradientStops[fractionInRoute] = associatedFeatureColor
                            gradientStops[nextDownfractionInRoute] = previousStopColor
                            previousStopColor = associatedFeatureColor
                        }
                    } else if previousStopColor != traversedRouteColor && previousStopColor != routeCasingColor {
                        // This leg is just after the current leg, assigned `routeCasingColor`.
                        let traveledLegFraction = legDistanceTraveled / routeDistance
                        let nextDownTraveledLeg = Double(CGFloat(traveledLegFraction).nextDown)
                        gradientStops[traveledLegFraction] = routeCasingColor
                        gradientStops[nextDownTraveledLeg] = previousStopColor
                        previousStopColor = routeCasingColor
                    }
                }
                legDistanceTraveled += legDistance
            }
            gradientStops = updateRouteLineGradientStops(fractionTraveled: fractionTraveled, gradientStops: gradientStops)
            
        } else {
            let percentTraveled = CGFloat(fractionTraveled)
            gradientStops[0.0] = traversedRouteColor
            if percentTraveled.nextDown >= 0.0 {
                gradientStops[Double(percentTraveled.nextDown)] = traversedRouteColor
            }
            gradientStops[Double(percentTraveled)] = routeCasingColor
        }
        
        return gradientStops
    }
    
    /**
     Given a congestion level, return its associated color.
     */
    func congestionColor(for congestionLevel: String?, isMain: Bool) -> UIColor {
        switch congestionLevel {
        case "low":
            return isMain ? trafficLowColor : alternativeTrafficLowColor
        case "moderate":
            return isMain ? trafficModerateColor : alternativeTrafficModerateColor
        case "heavy":
            return isMain ? trafficHeavyColor : alternativeTrafficHeavyColor
        case "severe":
            return isMain ? trafficSevereColor : alternativeTrafficSevereColor
        default:
            return isMain ? trafficUnknownColor : alternativeTrafficUnknownColor
        }
    }
}
