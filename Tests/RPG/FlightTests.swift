import Foundation

/// Flight: no gravity, lift climbs and sinks, blocks still block, the
/// ground lands it, a ceiling and a stamina cost.
func flightTests() {
    let open = SpatialGeometry(blocks: [])
    var flyer = SpatialPlayer(); flyer.position = SpatialVector(10.5, 10.5, 0)
    func run(_ player: inout SpatialPlayer, _ input: SpatialInput, seconds: Double, geometry: SpatialGeometry) {
        for _ in 0..<Int(seconds * 50) { SpatialPhysics.step(&player, input: input, dt: 0.02, geometry: geometry, previous: geometry) }
    }
    run(&flyer, SpatialInput(flying: true, lift: 1), seconds: 1, geometry: open)
    check(abs(flyer.position.z - SpatialFlight.climbSpeed) < 0.05 && !flyer.grounded, "flight: holding up climbs \(SpatialFlight.climbSpeed) per second (\(flyer.position.z))")
    let hover = flyer.position.z
    run(&flyer, SpatialInput(flying: true, lift: 0), seconds: 2, geometry: open)
    check(abs(flyer.position.z - hover) < 1e-9, "flight: no gravity while flying")
    var walker = flyer
    run(&walker, SpatialInput(), seconds: 2, geometry: open)
    check(walker.position.z == 0 && walker.grounded, "flight: ending it lets the body fall to the ground")
    var cruiser = SpatialPlayer(); cruiser.position = SpatialVector(20.5, 20.5, 2)
    var stroller = cruiser; stroller.position.z = 0
    run(&cruiser, SpatialInput(dx: 1, flying: true), seconds: 1, geometry: open)
    run(&stroller, SpatialInput(dx: 1), seconds: 1, geometry: open)
    check(abs((cruiser.position.x - 20.5) / (stroller.position.x - 20.5) - SpatialFlight.horizontalScale) < 0.05, "flight: faster than walking")
    run(&flyer, SpatialInput(flying: true, lift: 1), seconds: 20, geometry: open)
    check(flyer.position.z == SpatialFlight.maximumAltitude, "flight: stops at the altitude limit")
    run(&flyer, SpatialInput(flying: true, lift: -1), seconds: 20, geometry: open)
    check(flyer.position.z == 0 && flyer.grounded, "flight: sinking lands on the ground")

    // A wall: flying into it stops; flying over it works; landing on top.
    let wall = SpatialGeometry(blocks: (0..<30).map { SpatialBlock(id: "w\($0)", x: 30, y: $0, elevation: 0, thickness: 3) })
    var low = SpatialPlayer(); low.position = SpatialVector(28.5, 10.5, 1)
    run(&low, SpatialInput(dx: 1, flying: true), seconds: 2, geometry: wall)
    check(low.position.x < 30, "flight: a wall still stops the body (\(low.position.x))")
    var high = SpatialPlayer(); high.position = SpatialVector(28.5, 10.5, 4)
    run(&high, SpatialInput(dx: 1, flying: true), seconds: 1, geometry: wall)
    check(high.position.x > 31, "flight: over the wall's top the way is free")
    var roof = SpatialPlayer(); roof.position = SpatialVector(30.5, 10.5, 5)
    run(&roof, SpatialInput(flying: true, lift: -1), seconds: 2, geometry: wall)
    check(abs(roof.position.z - 3) < 1e-9 && roof.grounded, "flight: sinking onto a block lands on its top")
    var junk = SpatialPlayer(); junk.position = SpatialVector(5.5, 5.5, 1)
    run(&junk, SpatialInput(flying: true, lift: .nan), seconds: 1, geometry: open)
    check(junk.position.finite && junk.position.z == 1, "flight: a broken lift input is ignored")

    // Stamina: 6 a second in the air, carried across frames, never below 0.
    var carry = 0.0, stamina = 50
    for _ in 0..<4 { stamina = SpatialFlight.stamina(stamina, afterAirborne: 0.25, carry: &carry) }
    check(stamina == 44, "flight: one second in the air costs 6 stamina (\(stamina))")
    check(SpatialFlight.stamina(3, afterAirborne: 10, carry: &carry) == 0, "flight: stamina never goes below 0")
    print("RPG flight: climb, hover, cruise, walls, landing, stamina")
}

/// Bad vertices never reach a mesh (a NaN can black out a phone's frame).
func finiteMeshTests() {
    var positions: [Float] = [1, 2, 3, .nan, 0, 0, 5, 5, .infinity, 20_000, 0, 0]
    var normals: [Float] = [0, 1, 0, 0, 0, 0, .nan, 1, 0, 0, 0, 1]
    let rest: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], restN: [Float] = [0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0]
    let fixed = FiniteMesh.repair(positions: &positions, normals: &normals, restPositions: rest, restNormals: restN)
    check(fixed == 3 && positions == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], "mesh: broken and runaway positions go back to the rest pose")
    check(normals == [0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1], "mesh: zero and NaN normals take the rest normal, good ones stay")
    var bare: [Float] = [.nan, .nan, .nan], bareN: [Float] = [.nan, 0, 0]
    FiniteMesh.repair(positions: &bare, normals: &bareN, restPositions: [], restNormals: [])
    check(bare == [0, 0, 0] && bareN == [0, 1, 0], "mesh: with no rest pose a bad vertex becomes the origin, facing up")
    check(FiniteMesh.loopTime(2.5, period: 1) == 0.5 && FiniteMesh.loopTime(2.5, period: 0) == 0 && FiniteMesh.loopTime(.nan, period: 1) == 0 && FiniteMesh.loopTime(3, period: .nan) == 0,
          "mesh: a zero or broken clip period plays the first frame instead of NaN")
    print("RPG mesh: finite vertices")
}
