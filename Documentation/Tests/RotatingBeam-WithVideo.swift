import Foundation
import GIFModule
import HDL
import MolecularRenderer
import QuaternionModule

// MARK: - User-Facing Options

// 16 is reproducer for a bug, originally 10.
let beamDepth: Int = 16

// MARK: - GIF Recording Setup
let renderingOffline: Bool = true
let frameCount: Int = 60 * 5  // 5 seconds at 60 FPS
let gifFrameSkipRate: Int = 3  // Save every 3rd frame for 20 FPS GIF

let gifWidth = renderingOffline ? 1080 : 1080 * 3
let gifHeight = renderingOffline ? 1080 : 1080 * 3

var gif = GIF(
  width: gifWidth,
  height: gifHeight,
  loopCount: 0)
var gifImage = GIFModule.Image(width: gifWidth, height: gifHeight)

// Global time tracking for offline rendering
var currentTime: Float = 0

// MARK: - Compile Structures

let crossThickness: Int = 16
let crossSize: Int = 120
let actualWorldDimension: Float = 96
let paddedWorldDimension: Float = 128

func passivate(topology: inout Topology) {
  func createHydrogen(
    atomID: UInt32,
    orbital: SIMD3<Float>
  ) -> Atom {
    let atom = topology.atoms[Int(atomID)]

    var bondLength = atom.element.covalentRadius
    bondLength += Element.hydrogen.covalentRadius

    let position = atom.position + bondLength * orbital
    return Atom(position: position, element: .hydrogen)
  }

  let orbitalLists = topology.nonbondingOrbitals()

  var insertedAtoms: [Atom] = []
  var insertedBonds: [SIMD2<UInt32>] = []
  for atomID in topology.atoms.indices {
    let orbitalList = orbitalLists[atomID]
    for orbital in orbitalList {
      let hydrogen = createHydrogen(
        atomID: UInt32(atomID),
        orbital: orbital)
      let hydrogenID = topology.atoms.count + insertedAtoms.count
      insertedAtoms.append(hydrogen)

      let bond = SIMD2(
        UInt32(atomID),
        UInt32(hydrogenID))
      insertedBonds.append(bond)
    }
  }
  topology.atoms += insertedAtoms
  topology.bonds += insertedBonds
}

func createCross() -> Topology {
  let lattice = Lattice<Cubic> { h, k, l in
    Bounds {
      Float(crossSize) * h +
      Float(crossSize) * k +
      Float(2) * l
    }
    Material { .checkerboard(.silicon, .carbon) }

    for isPositiveX in [false, true] {
      for isPositiveY in [false, true] {
        let halfSize = Float(crossSize) / 2
        let center = halfSize * h + halfSize * k

        let directionX = isPositiveX ? h : -h
        let directionY = isPositiveY ? k : -k
        let halfThickness = Float(crossThickness) / 2

        Volume {
          Concave {
            Convex {
              Origin { center + halfThickness * directionX }
              Plane { isPositiveX ? h : -h }
            }
            Convex {
              Origin { center + halfThickness * directionY }
              Plane { isPositiveY ? k : -k }
            }
          }
          Replace { .empty }
        }
      }
    }
  }

  var reconstruction = Reconstruction()
  reconstruction.atoms = lattice.atoms
  reconstruction.material = .checkerboard(.silicon, .carbon)
  var topology = reconstruction.compile()
  passivate(topology: &topology)

  for atomID in topology.atoms.indices {
    var atom = topology.atoms[atomID]

    // This offset captures just one Si and one C for each unit cell on the
    // (001) surface. By capture, I mean that atom.position.z > 0. We want a
    // small number of static atoms in a 2 nm voxel that overlaps some moving
    // atoms.
    atom.position += SIMD3(0, 0, -0.800)

    // Shift the origin to allow larger beam depth, with fixed world dimension.
    atom.position.z -= actualWorldDimension / 2
    atom.position.z += 8

    // Shift so the structure is centered in X and Y.
    let latticeConstant = Constant(.square) {
      .checkerboard(.silicon, .carbon)
    }
    let halfSize = Float(crossSize) / 2
    atom.position.x -= halfSize * latticeConstant
    atom.position.y -= halfSize * latticeConstant

    topology.atoms[atomID] = atom
  }

  return topology
}

func createBeam() -> Topology {
  let lattice = Lattice<Cubic> { h, k, l in
    Bounds {
      Float(crossThickness) * h +
      Float(crossSize) * k +
      Float(beamDepth) * l
    }
    Material { .checkerboard(.silicon, .carbon) }
  }

  var reconstruction = Reconstruction()
  reconstruction.atoms = lattice.atoms
  reconstruction.material = .checkerboard(.silicon, .carbon)
  var topology = reconstruction.compile()
  passivate(topology: &topology)

  for atomID in topology.atoms.indices {
    var atom = topology.atoms[atomID]

    // Capture just one Si and one C for each unit cell. This time, capturing
    // happens if atom.position.z < 0.
    atom.position += SIMD3(0, 0, -0.090)

    // Shift so both captured surfaces fall in the [0, 2] nm range for sharing
    // a voxel.
    atom.position.z += 2

    // Shift the origin to allow larger beam depth, with fixed world dimension.
    atom.position.z -= actualWorldDimension / 2
    atom.position.z += 8

    // Shift so the structure is centered in X and Y.
    let latticeConstant = Constant(.square) {
      .checkerboard(.silicon, .carbon)
    }
    let halfThickness = Float(crossThickness) / 2
    let halfSize = Float(crossSize) / 2
    atom.position.x -= halfThickness * latticeConstant
    atom.position.y -= halfSize * latticeConstant

    topology.atoms[atomID] = atom
  }

  return topology
}

func analyze(topology: Topology) {
  print()
  print("atom count:", topology.atoms.count)
  do {
    var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for atom in topology.atoms {
      let position = atom.position
      minimum.replace(with: position, where: position .< minimum)
      maximum.replace(with: position, where: position .> maximum)
    }
    print("minimum:", minimum)
    print("maximum:", maximum)
  }
}

let cross = createCross()
let beam = createBeam()
analyze(topology: cross)
analyze(topology: beam)

// MARK: - Rotation Animation

@MainActor
func createRotatedBeam(frameID: Int) -> Topology {
  // 0.5 Hz -> 3 degrees/frame @ 60 Hz
  //
  // WARNING: Systems with different display refresh rates may have different
  // benchmark results. The benchmark should be robust to this variation in
  // degrees/frame.
  //
  // Solution: animate by clock.frames instead of the actual time. On 120 Hz
  // systems, the benchmark will rotate 2x faster than on 60 Hz systems.
  let angleDegrees: Float = 3 * Float(frameID)
  let rotation = Quaternion<Float>(
    angle: angleDegrees * Float.pi / 180,
    axis: SIMD3(0, 0, 1))

  // Circumvent a massive CPU-side bottleneck from 'rotation.act()'.
  let basis0 = rotation.act(on: SIMD3<Float>(1, 0, 0))
  let basis1 = rotation.act(on: SIMD3<Float>(0, 1, 0))
  let basis2 = rotation.act(on: SIMD3<Float>(0, 0, 1))

  var topology = beam
  for atomID in topology.atoms.indices {
    var atom = topology.atoms[atomID]

    var rotatedPosition: SIMD3<Float> = .zero
    rotatedPosition += basis0 * atom.position[0]
    rotatedPosition += basis1 * atom.position[1]
    rotatedPosition += basis2 * atom.position[2]
    atom.position = rotatedPosition

    topology.atoms[atomID] = atom
  }

  return topology
}

// MARK: - Launch Application

@MainActor
func createApplication() -> Application {
  // Set up the device.
  var deviceDesc = DeviceDescriptor()
  deviceDesc.deviceID = Device.fastestDeviceID
  let device = Device(descriptor: deviceDesc)

  // Set up the display.
  var displayDesc = DisplayDescriptor()
  displayDesc.device = device
  if renderingOffline {
    displayDesc.frameBufferSize = SIMD2<Int>(1080, 1080)
  } else {
    displayDesc.frameBufferSize = SIMD2<Int>(1080, 1080)
    displayDesc.monitorID = device.fastestMonitorID
  }
  let display = Display(descriptor: displayDesc)

  // Set up the application.
  var applicationDesc = ApplicationDescriptor()
  applicationDesc.device = device
  applicationDesc.display = display

  if renderingOffline {
    applicationDesc.upscaleFactor = 1
  } else {
    // What? We forgot to enable upscaling while originally creating this test?
    // It's better to leave the original code as-is, but it might cause FPS
    // problems on weaker GPUs. Ideally, we would use an upscale factor of 3 and
    // change the code in 'application.run' to call 'application.upscale'.
    //
    // Since the majority of the pixels never intersect an atom, the compute cost
    // for ray tracing is quite low. That's probably why the test didn't cause
    // performance issues.
    applicationDesc.upscaleFactor = 1
  }

  applicationDesc.addressSpaceSize = 4_000_000
  applicationDesc.voxelAllocationSize = 500_000_000
  applicationDesc.worldDimension = paddedWorldDimension
  let application = Application(descriptor: applicationDesc)

  return application
}
let application = createApplication()

for atomID in cross.atoms.indices {
  let atom = cross.atoms[atomID]
  application.atoms[atomID] = atom
}

@MainActor
func addRotatedBeam(frameID: Int) {
  let rotatedBeam = createRotatedBeam(frameID: frameID)
  let offset = cross.atoms.count

  // Circumvent a massive CPU-side bottleneck from @MainActor referencing to
  // 'application' from the global scope.
  let applicationCopy = application

  for atomID in rotatedBeam.atoms.indices {
    let atom = rotatedBeam.atoms[atomID]
    applicationCopy.atoms[offset + atomID] = atom
  }
}

// MARK: - Main Loop

// This test only supports offline rendering
assert(renderingOffline, "This test only supports offline rendering")

print("Recording rotating beam animation offline - will save as GIF...")
print("Starting animation loop...")

for frameID in 1...frameCount {
  // Update time for this frame (60 FPS)
  currentTime = Float(frameID) / 60.0

  addRotatedBeam(frameID: frameID)
  application.camera.position = SIMD3(0, 0, (actualWorldDimension / 2) - 8)

  // Render and save frames for GIF every few frames
  if frameID % gifFrameSkipRate == 0 {
    let image = application.render()

    // Convert to GIF format
    for y in 0..<gifImage.height {
      for x in 0..<gifImage.width {
        let pixelIndex = y * gifImage.width + x
        let pixel = image.pixels[pixelIndex]

        let r = UInt8(max(0, min(255, Float(pixel.x) * 255)))
        let g = UInt8(max(0, min(255, Float(pixel.y) * 255)))
        let b = UInt8(max(0, min(255, Float(pixel.z) * 255)))

        let color = Color(red: r, green: g, blue: b)
        gifImage[y, x] = color
      }
    }

    let frame = Frame(
      image: gifImage,
      delayTime: 5, // ~20 FPS
      localQuantization: OctreeQuantization(fromImage: gifImage)
    )
    gif.frames.append(frame)

    print("Recorded frame \(frameID / gifFrameSkipRate) / \(frameCount / gifFrameSkipRate)")
  }
}

print("Animation complete, \(gif.frames.count) frames recorded")
print("Encoding GIF...")
let data = try! gif.encoded()
let filePath = "Art/rotating-beam.gif"
let succeeded = FileManager.default.createFile(
  atPath: filePath,
  contents: data
)
if succeeded {
  print("Saved GIF to \(filePath)")
} else {
  print("Failed to save GIF")
}