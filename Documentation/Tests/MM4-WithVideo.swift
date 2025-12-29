import Foundation
import GIFModule
import HDL
import MM4
import MolecularRenderer
import QuaternionModule

// MARK: - User-Facing Options

let renderingOffline: Bool = true
let frameCount: Int = 60 * 3  // 3 seconds at 60 FPS
let gifFrameSkipRate: Int = 2  // Save every 2nd frame for 30 FPS GIF

// MARK: - Compile Structure

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

func createTopology() -> Topology {
  let lattice = Lattice<Cubic> { h, k, l in
    Bounds { 4 * (h + k + l) }
    Material { .checkerboard(.carbon, .silicon) }
  }
  var reconstruction = Reconstruction()
  reconstruction.atoms = lattice.atoms
  reconstruction.material = .checkerboard(.silicon, .carbon)
  var topology = reconstruction.compile()
  passivate(topology: &topology)

  // Create a force field for dynamics
  var forceFieldDesc = MM4ForceFieldDescriptor()
  forceFieldDesc.atomicNumbers = topology.atoms.map(\.atomicNumber)
  forceFieldDesc.bonds = topology.bonds
  let forceField = MM4ForceField(descriptor: forceFieldDesc)

  // Minimize the structure
  forceField.positions = topology.atoms.map(\.position)
  forceField.minimize(tolerance: 1.0)

  // Update topology with minimized positions
  for i in topology.atoms.indices {
    topology.atoms[i].position = forceField.positions[i]
  }

  return topology
}

// MARK: - Rendering Setup

@MainActor
func createApplication() -> Application {
  var deviceDesc = DeviceDescriptor()
  deviceDesc.deviceID = Device.fastestDeviceID
  let device = Device(descriptor: deviceDesc)

  var displayDesc = DisplayDescriptor()
  displayDesc.device = device
  displayDesc.frameBufferSize = SIMD2<Int>(1440, 1080)
  displayDesc.monitorID = device.fastestMonitorID
  let display = Display(descriptor: displayDesc)

  var applicationDesc = ApplicationDescriptor()
  applicationDesc.device = device
  applicationDesc.display = display
  applicationDesc.upscaleFactor = 3

  applicationDesc.addressSpaceSize = 4_000_000
  applicationDesc.voxelAllocationSize = 500_000_000
  applicationDesc.worldDimension = 64
  let application = Application(descriptor: applicationDesc)

  return application
}

let application = createApplication()
let topology = createTopology()

// Set up force field for dynamics
var forceFieldDesc = MM4ForceFieldDescriptor()
forceFieldDesc.atomicNumbers = topology.atoms.map(\.atomicNumber)
forceFieldDesc.bonds = topology.bonds
let forceField = MM4ForceField(descriptor: forceFieldDesc)
forceField.positions = topology.atoms.map(\.position)

// Initialize velocities for room temperature
forceField.velocities = (0..<topology.atoms.count).map { _ in
  SIMD3<Float>(repeating: 0) // Start with zero velocity, will thermalize
}

// Thermalize to 300K
let boltzmann = Float(1.380649e-23)
let temperature: Float = 300
let targetKE = 1.5 * boltzmann * temperature * Float(topology.atoms.count)
forceField.thermalize(targetKE: targetKE)

// MARK: - GIF Recording Setup

var gif = GIF()
var gifImage = GIFModule.Image(width: 1440 * 3, height: 1080 * 3)

// MARK: - Simulation Loop

@MainActor
func modifyAtoms() {
  // Run dynamics for 1 fs per frame
  forceField.simulate(timeStep: 1e-15, steps: 1)

  // Update application atoms
  application.atoms = forceField.positions.enumerated().map { (i, position) in
    Atom(position: position, element: topology.atoms[i].element)
  }
}

@MainActor
func modifyCamera() {
  let time = Float(application.frameID) / 60.0  // seconds

  // Slow rotation around the molecule
  let angle = time * 0.1 * 2 * .pi  // Full rotation every ~63 seconds
  let radius: Float = 3.0  // nm

  application.camera.position = SIMD3<Float>(
    radius * cos(angle),
    radius * sin(angle),
    1.0
  )

  application.camera.basis.0 = SIMD3(1, 0, 0)
  application.camera.basis.1 = SIMD3(0, 1, 0)
  application.camera.basis.2 = SIMD3(0, 0, 1)
  application.camera.fovAngleVertical = .pi / 180 * 60
}

// MARK: - Main Loop

application.run {
  modifyAtoms()
  modifyCamera()

  let frameID = application.frameID

  // Render and save frames for GIF
  if frameID % gifFrameSkipRate == 0 {
    var image = application.render()
    image = application.upscale(image: image)

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
      delayTime: 3, // ~30 FPS
      localQuantization: OctreeQuantization(fromImage: gifImage)
    )
    gif.frames.append(frame)

    print("Recorded frame \(frameID / gifFrameSkipRate) / \(frameCount / gifFrameSkipRate)")
  }

  var image = application.render()
  image = application.upscale(image: image)
  application.present(image: image)

  // Exit after recording all frames
  if frameID >= frameCount {
    print("Encoding GIF...")
    let data = try! gif.encoded()
    let filePath = ".build/mm4-molecular-dynamics.gif"
    let succeeded = FileManager.default.createFile(
      atPath: filePath,
      contents: data
    )
    if succeeded {
      print("Saved GIF to \(filePath)")
    }
    exit(0)
  }
}