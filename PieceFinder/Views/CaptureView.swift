import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case illustration
    case realPiece
    case page

    var id: String { rawValue }

    var label: String {
        switch self {
        case .illustration: return "Piece"
        case .realPiece:    return "Real"
        case .page:         return "Page"
        }
    }

    var title: String {
        switch self {
        case .illustration: return "Photograph a single piece"
        case .realPiece:    return "Photograph a real piece"
        case .page:         return "Photograph the piece box"
        }
    }

    var instructions: String {
        switch self {
        case .illustration:
            return "One piece drawing from the manual\nCentre it in the frame"
        case .realPiece:
            return "A real brick on a flat surface\nFill the frame with the piece"
        case .page:
            return "The bordered box with pieces and\nquantity markers (1x, 2x, ...)\nFill the frame with just the box"
        }
    }
}

struct CaptureView: View {
    @EnvironmentObject var appState: AppState
    @State private var showImagePicker = false
    @State private var capturedImage: UIImage?
    @State private var mode: CaptureMode = .page

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Picker("Mode", selection: $mode) {
                    ForEach(CaptureMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 16)

                Spacer()

                Text(mode.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(mode.instructions)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                Spacer()

                if appState.isProcessingReference {
                    ProgressView("Analyzing pieces...")
                        .tint(.white)
                        .foregroundColor(.white)
                } else {
                    Button {
                        showImagePicker = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 72, height: 72)
                            Circle()
                                .stroke(.white, lineWidth: 3)
                                .frame(width: 82, height: 82)
                        }
                    }
                }

                if let error = appState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Spacer()
                    .frame(height: 40)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $capturedImage)
        }
        .onChange(of: capturedImage) { _, newImage in
            guard let image = newImage else { return }
            switch mode {
            case .illustration: appState.addSinglePieceIllustration(from: image)
            case .realPiece:    appState.addRealPiece(from: image)
            case .page:         appState.addReferences(from: image)
            }
            capturedImage = nil
        }
    }
}

// MARK: - UIImagePickerController wrapper

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // UIImagePickerController crashes if you set an unavailable source
        // type. Camera is unavailable in the simulator and on devices without
        // one; fall back to the photo library so capture still works.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
