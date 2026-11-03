import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// «Modifica» → «Regola»: light, colour and detail, like a photo app's adjustments, with Core Image.
/// Every slider goes from -100 to +100 (0 = unchanged); the same chain runs on the preview and on the full photo.
extension PhotoEditor {
    struct Adjustments: Equatable, Sendable {
        enum Key: String, CaseIterable, Identifiable, Sendable {
            case exposure, brightness, contrast, highlights, shadows, whites, blacks, gamma
            case temperature, tint, saturation, vibrance, hue
            case clarity, sharpness

            var id: String { rawValue }

            var title: String {
                switch self {
                case .exposure: return L("Esposizione")
                case .brightness: return L("Luminosità")
                case .contrast: return L("Contrasto")
                case .highlights: return L("Alte luci")
                case .shadows: return L("Ombre")
                case .whites: return L("Bianchi")
                case .blacks: return L("Neri")
                case .gamma: return L("Gamma")
                case .temperature: return L("Temperatura")
                case .tint: return L("Tinta")
                case .saturation: return L("Saturazione")
                case .vibrance: return L("Vividezza")
                case .hue: return L("Tonalità")
                case .clarity: return L("Chiarezza")
                case .sharpness: return L("Nitidezza")
                }
            }

            /// The value as the slider shows it: EV for exposure, degrees for hue, else -100…+100.
            func label(_ v: Double) -> String {
                switch self {
                case .exposure: return String(format: "%+.2f EV", v / 50)
                case .hue: return String(format: "%+.0f°", v * 1.8)
                default: return String(format: "%+.0f", v)
                }
            }
        }

        static let groups: [(title: String, keys: [Key])] = [
            ("Luce", [.exposure, .brightness, .contrast, .highlights, .shadows, .whites, .blacks, .gamma]),
            ("Colore", [.temperature, .tint, .saturation, .vibrance, .hue]),
            ("Dettaglio", [.clarity, .sharpness]),
        ]

        var values: [Key: Double] = [:]

        subscript(key: Key) -> Double {
            get { values[key] ?? 0 }
            set { values[key] = newValue == 0 ? nil : min(max(newValue, -100), 100) }
        }

        var isIdentity: Bool { values.isEmpty }

        /// The adjusted image. Detail filters scale with the image size, so the preview looks like the saved photo.
        func apply(to input: CIImage) -> CIImage {
            guard !isIdentity else { return input }
            var image = input
            let side = max(input.extent.width, input.extent.height)
            func v(_ k: Key) -> Double { self[k] / 100 }   // -1…1

            if v(.exposure) != 0 {
                let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(v(.exposure) * 2)
                image = f.outputImage ?? image
            }
            // Highlights down and shadows up/down: Core Image's highlight/shadow filter (it can only lower highlights).
            if v(.highlights) < 0 || v(.shadows) != 0 {
                let f = CIFilter.highlightShadowAdjust(); f.inputImage = image
                f.highlightAmount = Float(1 + min(v(.highlights), 0))
                f.shadowAmount = Float(v(.shadows))
                image = f.outputImage ?? image
            }
            // Curves and contrast work on what the eye sees (sRGB values), not on linear light: otherwise
            // their middle point sits too high and more contrast also darkens the photo.
            let perceptual = v(.highlights) > 0 || v(.whites) != 0 || v(.blacks) != 0
                || v(.brightness) != 0 || v(.contrast) != 0
            if perceptual { image = image.applyingFilter("CILinearToSRGBToneCurve") }
            // Highlights up, whites and blacks: a tone curve.
            if v(.highlights) > 0 || v(.whites) != 0 || v(.blacks) != 0 {
                let f = CIFilter.toneCurve(); f.inputImage = image
                let b = v(.blacks) * 0.15, w = v(.whites) * 0.15, h = max(v(.highlights), 0) * 0.1
                f.point0 = CGPoint(x: 0, y: max(0, b)); f.point1 = CGPoint(x: 0.25, y: 0.25 + b * 0.5)
                f.point2 = CGPoint(x: 0.5, y: 0.5 + (b + w) * 0.25)
                f.point3 = CGPoint(x: 0.75, y: min(1, 0.75 + w * 0.5 + h)); f.point4 = CGPoint(x: 1, y: min(1, 1 + w))
                image = f.outputImage ?? image
            }
            if v(.brightness) != 0 || v(.contrast) != 0 {
                let f = CIFilter.colorControls(); f.inputImage = image
                f.brightness = Float(v(.brightness) * 0.3)
                f.contrast = Float(1 + v(.contrast) * 0.5)
                f.saturation = 1
                image = f.outputImage ?? image
            }
            if perceptual { image = image.applyingFilter("CISRGBToneCurveToLinear") }
            if v(.saturation) != 0 {
                let f = CIFilter.colorControls(); f.inputImage = image; f.saturation = Float(1 + v(.saturation))
                image = f.outputImage ?? image
            }
            if v(.gamma) != 0 {
                let f = CIFilter.gammaAdjust(); f.inputImage = image
                f.power = Float(pow(2, -v(.gamma)))   // +100 brightens the mid-tones, -100 darkens them
                image = f.outputImage ?? image
            }
            if v(.temperature) != 0 || v(.tint) != 0 {
                let f = CIFilter.temperatureAndTint(); f.inputImage = image
                f.neutral = CIVector(x: 6500, y: 0)
                f.targetNeutral = CIVector(x: 6500 - v(.temperature) * 3000, y: -v(.tint) * 100)   // + = magenta
                image = f.outputImage ?? image
            }
            if v(.vibrance) != 0 {
                let f = CIFilter.vibrance(); f.inputImage = image; f.amount = Float(v(.vibrance))
                image = f.outputImage ?? image
            }
            if v(.hue) != 0 {
                let f = CIFilter.hueAdjust(); f.inputImage = image; f.angle = Float(v(.hue) * .pi)
                image = f.outputImage ?? image
            }
            if v(.clarity) != 0 {
                // Local contrast: an unsharp mask with a wide radius.
                let f = CIFilter.unsharpMask(); f.inputImage = image
                f.radius = Float(side * 0.02); f.intensity = Float(v(.clarity) * 0.8)
                image = f.outputImage ?? image
            }
            if v(.sharpness) > 0 {
                let f = CIFilter.sharpenLuminance(); f.inputImage = image
                f.sharpness = Float(v(.sharpness) * 1.5); f.radius = Float(max(1, side / 1500))
                image = f.outputImage ?? image
            } else if v(.sharpness) < 0 {
                let f = CIFilter.gaussianBlur(); f.inputImage = image.clampedToExtent()
                f.radius = Float(-v(.sharpness) * side / 400)
                image = f.outputImage ?? image
            }
            return image.cropped(to: input.extent)
        }

        /// Shared: creating a Core Image context is slow, rendering with one is not.
        static let context = CIContext(options: [.cacheIntermediates: false])

        func render(_ image: CGImage) -> CGImage? {
            guard !isIdentity else { return image }
            let output = apply(to: CIImage(cgImage: image))
            return Self.context.createCGImage(output, from: output.extent, format: .RGBA8,
                                              colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        }
    }
}
