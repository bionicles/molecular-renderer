import Foundation
import GIFModule
import HDL
import MolecularRenderer
import QuaternionModule

// MARK: - User-Facing Options

let frameCount: Int = 60 * 8  // 8 seconds at 60 FPS

// MARK: - Application Setup

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

// State variable to facilitate atom transactions for the animation.
enum AnimationState {
  case isopropanol
  case silane
}
var animationState: AnimationState?

func createIsopropanol() -> [SIMD4<Float>] {
  return [
    Atom(position: SIMD3( 2.0186, -0.2175,  0.7985) * 0.1, element: .hydrogen),
    Atom(position: SIMD3( 1.4201, -0.2502, -0.1210) * 0.1, element: .carbon),
    Atom(position: SIMD3( 1.6783,  0.6389, -0.7114) * 0.1, element: .hydrogen),
    Atom(position: SIMD3( 1.7345, -1.1325, -0.6927) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.0726, -0.3145,  0.1833) * 0.1, element: .carbon),
    Atom(position: SIMD3(-0.2926, -1.2317,  0.7838) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.3758,  0.8195,  0.9774) * 0.1, element: .oxygen),
    Atom(position: SIMD3(-1.3159,  0.8236,  1.0972) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.8901, -0.3435, -1.1071) * 0.1, element: .carbon),
    Atom(position: SIMD3(-0.7278,  0.5578, -1.7131) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.6126, -1.2088, -1.7220) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-1.9673, -0.4150, -0.9062) * 0.1, element: .hydrogen),
  ]
}

func createSilane() -> [SIMD4<Float>] {
  return [
    Atom(position: SIMD3( 0.0000,  0.0000,  0.0000) * 0.1, element: .silicon),
    Atom(position: SIMD3( 0.8544,  0.8544,  0.8544) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.8544, -0.8544,  0.8544) * 0.1, element: .hydrogen),
    Atom(position: SIMD3(-0.8544,  0.8544, -0.8544) * 0.1, element: .hydrogen),
    Atom(position: SIMD3( 0.8544, -0.8544, -0.8544) * 0.1, element: .hydrogen),
  ]
}

// MARK: - GIF Recording

var gif = GIF(
  width: 1440 * 3,  // upscaled resolution
  height: 1080 * 3,
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

  for pixelIndex in 0..<image.pixels.count {
    let pixel = image.pixels[pixelIndex]

    // Convert from float [0,1] to byte [0,255]
    let r = UInt8(max(0, min(255, Float(pixel.x) * 255)))
    let g = UInt8(max(0, min(255, Float(pixel.y) * 255)))
    let b = UInt8(max(0, min(255, Float(pixel.z) * 255)))

    let color = Color(
      red: r,
      green: g,
      blue: b)

    let y = pixelIndex / image.width
    let x = pixelIndex % image.width
    gifImage[y, x] = color
  }

  // Octree quantization for better colors
  let quantization = OctreeQuantization(fromImage: gifImage)

  // 30 FPS timing (33ms delay) for smoother animation
  let frame = Frame(
    image: gifImage,
    delayTime: 3,
    localQuantization: quantization)
  gif.frames.append(frame)
}

// MARK: - Animation

@MainActor
func modifyAtoms() {
  // 0.5 Hz rotation rate
  let time = Float(application.frameID) / 60.0  // seconds
  let angleDegrees = 0.5 * time * 360
  let rotation = Quaternion<Float>(
    angle: Float.pi / 180 * angleDegrees,
    axis: SIMD3(0, 1, 0))

  let roundedDownTime = Int((time / 3).rounded(.down))
  if roundedDownTime % 2 == 0 {
    let isopropanol = createIsopropanol()
    if animationState == .silane {
      for atomID in 12..<17 {
        application.atoms[atomID] = nil
      }
    }

    animationState = .isopropanol
    for i in isopropanol.indices {
      let atomID = 0 + i
      var atom = isopropanol[i]
      atom.position = rotation.act(on: atom.position)
      application.atoms[atomID] = atom
    }
  } else {
    let silane = createSilane()
    if animationState == .isopropanol {
      for atomID in 0..<12 {
        application.atoms[atomID] = nil
      }
    }

    animationState = .silane
    for i in silane.indices {
      let atomID = 12 + i
      var atom = silane[i]
      atom.position = rotation.act(on: atom.position)
      application.atoms[atomID] = atom
    }
  }
}

@MainActor
func modifyCamera() {
  // 0.1 Hz rotation rate
  let time = Float(application.frameID) / 60.0  // seconds
  let angleDegrees = 0.1 * time * 360
  let rotation = Quaternion<Float>(
    angle: Float.pi / 180 * angleDegrees,
    axis: SIMD3(-1, 0, 0))

  // Place the camera 1.0 nm away from the origin.
  application.camera.position = rotation.act(on: SIMD3(0, 0, 1.00))

  application.camera.basis.0 = rotation.act(on: SIMD3(1, 0, 0))
  application.camera.basis.1 = rotation.act(on: SIMD3(0, 1, 0))
  application.camera.basis.2 = rotation.act(on: SIMD3(0, 0, 1))
  application.camera.fovAngleVertical = Float.pi / 180 * 40
}

// MARK: - Main Loop

print("Starting upscaling molecular animation video recording...")
print("This will run for \(frameCount / 60) seconds at 60 FPS")

application.run {
  modifyAtoms()
  modifyCamera()

  let frameID = application.frameID

  // Record every 2nd frame for 30 FPS output
  if frameID % 2 == 0 {
    recordFrame()
  }

  // Exit after recording all frames
  if frameID >= frameCount {
    print("Recording complete. Encoding GIF...")

    // Encode and save GIF
    let data = try! gif.encoded()
    let packagePath = FileManager.default.currentDirectoryPath
    let filePath = "\(packagePath)/Art/upscaling-molecular-animation.gif"

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