import ObertonCore
import SwiftUI

struct LayoutSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Where the dictation overlay and the Read aloud player appear, and how solid they look. Drag either one to move it until Oberton restarts.")
            FieldLabel("Dictation overlay")
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ObSwitch("Show the overlay while dictating", isOn: $model.settings.showOverlay)
                    Hairline()
                    HStack {
                        Text("Opacity").font(Ob.sans(13.5))
                        Spacer()
                        Text("\(Int((model.settings.overlayOpacity * 100).rounded()))%").font(Ob.mono(12))
                    }
                    .padding(.top, 12)
                    Slider(value: $model.settings.overlayOpacity, in: 0.3...1).padding(.bottom, 12)
                    Hairline()
                    HStack {
                        Text("Position").font(Ob.sans(13.5))
                        Spacer()
                        Text(model.settings.overlayPosition.title).font(Ob.sans(12)).foregroundStyle(ob.muted)
                    }
                    .padding(.top, 12).padding(.bottom, 8)
                    PositionPicker(position: $model.settings.overlayPosition)
                    Caption("The overlay stays dark in both themes, so it reads over any app.", size: 12).padding(.top, 10)
                }
                .padding(EdgeInsets(top: 6, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity)
                Hairline(vertical: true)
                preview.frame(maxWidth: .infinity, minHeight: 200)
            }
            .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
            #else
            Caption("On iPhone the dictation pill appears at the bottom of Oberton's own screen.")
            #endif
        }
    }

    /// A live preview: placeholder lines of an app, and the pill at the slider's opacity.
    private var preview: some View {
        ZStack(alignment: model.settings.overlayPosition.alignment) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0.9, 0.7, 0.8, 0.5], id: \.self) { w in
                    GeometryReader { g in Rectangle().fill(ob.divider).frame(width: g.size.width * w, height: 6) }.frame(height: 6)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                Circle().fill(Color(hex: 0xFF4636)).frame(width: 8, height: 8)
                Text("0:07").font(Ob.mono(12)).foregroundStyle(Color(hex: 0xE8E7E3))
                Text(model.activeProfile.name.uppercased()).font(Ob.mono(11)).foregroundStyle(Color(hex: 0xE8E7E3, alpha: 0.72)).lineLimit(1)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Capsule().fill(Color(hex: 0x0D0D0C, alpha: model.settings.overlayOpacity)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(12)
        }
        .background(ob.subtle)
    }
}
