import Foundation
import GIFModule
import HDL
import MM4
import MolecularRenderer
import QuaternionModule

// MARK: - User-Facing Options

let renderingOffline: Bool = true
let frameCount: Int = 60 * 3  // 3 seconds at 60 FPS

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
    Bounds { 1 * (h + k + l) }
    Material { .checkerboard(.carbon, .silicon) }
  }
  var reconstruction = Reconstruction()
  reconstruction.atoms = lattice.atoms
  reconstruction.material = .checkerboard(.silicon, .carbon)
  var topology = reconstruction.compile()
  passivate(topology: &topology)

  return topology
}

func createSystem(topology: Topology) -> MM4ForceField {
  var descriptor = MM4ForceFieldDescriptor()
  descriptor.atomicNumbers = topology.atoms.map(\.atomicNumber)
  descriptor.bonds = topology.bonds.map { SIMD2($0[0], $0[1]) }
  descriptor.parameters = .init()

  var forceField = MM4ForceField(descriptor: descriptor)
  forceField.positions = topology.atoms.map(\.position)
  return forceField
}

@MainActor
func createApplication() -> Application {
  // Set up the device.
  var deviceDesc = DeviceDescriptor()
  deviceDesc.deviceID = Device.fastestDeviceID
  let device = Device(descriptor: deviceDesc)

  // Set up the display.
  var displayDesc = DisplayDescriptor()
  displayDesc.device = device
  displayDesc.frameBufferSize = SIMD2<Int>(1440, 1080)
  displayDesc.monitorID = device.fastestMonitorID
  let display = Display(descriptor: displayDesc)

  // Set up the application.
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
var system = createSystem(topology: topology)

// MARK: - GIF Recording

var gif = GIF(
  width: 1440,
  height: 1080,
  loopCount: 0,
  useGlobalColorTable: true)

@MainActor
func recordFrame() {
  var image = application.render()
  image = application.upscale(image: image)

  // Convert to GIF format
  var gifImage = GIFModule.Image(
    width: image.width,
    height: image.height)

  for y in 0..<image.height {
    for x in 0..<image.width {
      let pixelIndex = y * image.width + x
      let pixel = image.pixels[pixelIndex]

      // Convert from float [0,1] to byte [0,255]
      let r = UInt8(max(0, min(255, Float(pixel.x) * 255)))
      let g = UInt8(max(0, min(255, Float(pixel.y) * 255)))
      let b = UInt8(max(0, min(255, Float(pixel.z) * 255)))

      let color = Color(
        red: r,
        green: g,
        blue: b)

      gifImage[y, x] = color
    }
  }

  // Octree quantization for better colors
  let quantization = OctreeQuantization(fromImage: gifImage)

  // 20 FPS timing (50ms delay)
  let frame = Frame(
    image: gifImage,
    delayTime: 5,
    localQuantization: quantization)
  gif.frames.append(frame)
}

// MARK: - Animation

@MainActor
func modifyAtoms() {
  // Update atom positions from molecular dynamics
  let positions = system.positions
  for i in topology.atoms.indices {
    var atom = topology.atoms[i]
    atom.position = positions[i]
    application.atoms[i] = atom
  }
}

@MainActor
func modifyCamera() {
  let time = Float(application.frameID) / 60.0  // seconds

  // Smooth rotation around the molecule
  let angle = time * 30 * .pi / 180  // 30 degrees per second
  let distance: Float = 3.0  // nm

  let cameraPos = SIMD3<Float>(
    distance * cos(angle),
    distance * sin(angle * 0.7),
    distance * sin(angle * 0.5) + 1.0
  )

  application.camera.position = cameraPos
  application.camera.basis.0 = SIMD3(1, 0, 0)
  application.camera.basis.1 = SIMD3(0, 1, 0)
  application.camera.basis.2 = SIMD3(0, 0, 1)
  application.camera.fovAngleVertical = Float.pi / 180 * 45
}

// MARK: - Main Loop

print("Starting MM4 molecular dynamics video recording...")
print("This will run for \(frameCount / 60) seconds at 60 FPS")

application.run {
  modifyAtoms()
  modifyCamera()

  let frameID = application.frameID

  // Record every frame for smooth animation
  recordFrame()

  // Update physics (2 fs timesteps)
  system.integrate(timeStep: 0.002)  // picoseconds

  // Exit after recording all frames
  if frameID >= frameCount {
    print("Recording complete. Encoding GIF...")

    // Encode and save GIF
    let data = try! gif.encoded()
    let packagePath = FileManager.default.currentDirectoryPath
    let filePath = "\(packagePath)/Art/mm4-molecular-dynamics.gif"

    let succeeded = FileManager.default.createFile(
      atPath: filePath,
      contents: data)

    if succeeded {
      let encodedSize = String(format: "%.1f", Float(data.count) / 1e6)
      print("Saved \(encodedSize) MB GIF to \(filePath)")
    } else {
      print("Failed to save GIF")
    }

    exit(0)
  }
}