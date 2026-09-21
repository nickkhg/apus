import Foundation

/// Metal API Validation, which Xcode turns on for the programs that it runs.
///
/// Validation stops this program in MoltenVK, at a fault that belongs to
/// another project:
///
///     _validateReplaceRegion:252: failed assertion `Replace Region
///     Validation bytesPerRow(6619) must be a multiple of
///     MTLPixelFormatBGRA8Unorm pixel bytes(4).
///
/// Zink binds memory to an image, MoltenVK writes that memory into a Metal
/// texture, and the length of a row that MoltenVK computes is not a whole
/// count of pixels. The number follows the size of the screen: 6619 on one
/// Mac, 13238 on a Mac whose window has two times the pixels. The frames
/// themselves are right. Metal alone accepts the row, and validation makes
/// it fatal.
///
/// The Makefile takes the variables away from the machine, and that was not
/// enough: a build from Xcode still stopped here. Therefore the program
/// takes them away from itself, before it makes a Metal device. Metal reads
/// these names when it makes the first device, so this has to run first.
///
/// APUS_METAL_VALIDATION=1 keeps them, for a person who looks at this.
enum MetalValidation {
    /// The names that turn validation on. Each one of the first two starts
    /// the fault above by itself, which a test on this machine showed.
    private static let switches = [
        "METAL_DEVICE_WRAPPER_TYPE",
        "MTL_DEBUG_LAYER",
        "MTL_DEBUG_LAYER_ERROR_MODE",
        "MTL_SHADER_VALIDATION",
        "MTL_SHADER_VALIDATION_ERROR_MODE",
        "METAL_ERROR_MODE",
        "METAL_DEBUG_ERROR_MODE",
    ]

    /// Takes the validation switches out of this process.
    ///
    /// It says which names it found. A Mac that stops here again names the
    /// switch that this list does not have, so the next step needs no guess.
    static func quieten() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["APUS_METAL_VALIDATION"] != "1" else {
            log("Metal validation stays on (APUS_METAL_VALIDATION=1)")
            return
        }

        var removed: [String] = []
        for name in switches where environment[name] != nil {
            unsetenv(name)
            removed.append(name)
        }
        if !removed.isEmpty {
            log("Metal validation off for this machine: \(removed.joined(separator: " "))")
        }

        // Anything else of these two families, for a name that this list
        // does not know. It says the names and keeps them, because a name
        // that no test here has seen is not one to take away in silence.
        let others = environment.keys
            .filter { ($0.hasPrefix("MTL_") || $0.hasPrefix("METAL_")) && !switches.contains($0) }
            .sorted()
        if !others.isEmpty {
            log("Metal names that this program leaves alone: \(others.joined(separator: " "))")
        }
    }
}
