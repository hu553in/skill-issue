import AVFoundation
import SwiftUI

struct CaptureSettingsView: View {
    @ObservedObject var model: Model
    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.spacing) {
            Picker(
                "Microphone",
                selection: Binding(get: { model.microphone }, set: model.selectMicrophone)
            ) {
                Text("Off").tag(String?.none)
                Text("System default").tag(String?.some(""))
                ForEach(microphones, id: \.uniqueID) {
                    Text($0.localizedName).tag(String?.some($0.uniqueID))
                }
                if let selected = model.microphone, !selected.isEmpty,
                    !microphones.contains(where: { $0.uniqueID == selected })
                {
                    Text("Unavailable microphone").tag(String?.some(selected))
                }
            }.disabled(!model.canConfigureSession).help(model.lockReason ?? "")
            HStack(spacing: SettingsLayout.spacing) {
                Toggle(
                    "System audio",
                    isOn: Binding(
                        get: { model.captureInputs.systemAudio }, set: model.setSystemAudio)
                ).toggleStyle(.switch).fixedSize()
                Toggle(
                    "Include screenshot",
                    isOn: Binding(
                        get: { model.captureInputs.screenshots }, set: model.setScreenshots)
                ).toggleStyle(.switch).fixedSize()
                    .help(
                        model.lockReason ?? "Capture the main display with each answer request."
                    )
                Spacer(minLength: 0)
            }.disabled(!model.canConfigureSession).help(model.lockReason ?? "")
            if let reason = model.captureInputs.unavailableReason {
                Text(reason).font(.callout)
                    .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
            }
        }
    }
}
