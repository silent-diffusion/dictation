import ObertonCore
import SwiftUI

/// C.2 Layout (LayoutPage.xaml): two cards, the dictation overlay and the Read aloud player, each with its switch,
/// opacity, position picker and caption on the left and a live preview on the right.
struct LayoutSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Caption("Where the dictation overlay and the Read aloud player appear on your screen, and how much of their background shows.")
            FieldLabel("Dictation overlay")
            card {
                ObSwitch("Show the overlay while dictating", isOn: $model.settings.showOverlay)
                divider
                opacity($model.settings.overlayOpacity, name: "Overlay opacity")
                divider
                position(ReaderPositionPicker.describe(model.settings.overlayPosition))
                PositionPicker(position: $model.settings.overlayPosition, name: "Overlay position").padding(.top, 8).padding(.bottom, 12)
                Caption("The overlay stays dark in both themes so it reads on top of any window. The preview approval always shows, even with the overlay off.", bottom: 0)
            } preview: {
                overlayPreview
            }
            FieldLabel("Read aloud player").padding(.top, 8)
            card {
                ObSwitch("Same place as the dictation overlay", isOn: ReaderPositionPicker.samePlaceBinding(model))
                divider
                opacity($model.settings.readerOpacity, name: "Read aloud player opacity")
                divider
                position(ReaderPositionPicker.placeName(model.settings) + (model.settings.readerPosition == .withOverlay ? " (with the overlay)" : ""))
                ReaderPositionPicker(name: "Read aloud player position").padding(.top, 8).padding(.bottom, 12)
                Caption("The player that reads text aloud. Like the dictation overlay it stays dark in both themes, and you can drag it while it reads.", bottom: 0)
            } preview: {
                ReaderPreview(opacity: model.settings.readerOpacity)
            }
            #else
            Caption("On iPhone the dictation pill appears at the bottom of Oberton's own screen.")
            #endif
        }
    }

    /// A hairline card in two equal columns, both inside the card's 1 px line: the controls (Margin 18,6,18,16) and the
    /// preview on the subtle wash.
    private func card<Controls: View, Preview: View>(@ViewBuilder _ controls: () -> Controls, @ViewBuilder preview: () -> Preview) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { controls() }
                .padding(EdgeInsets(top: 6, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
            preview()
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                .clipped()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Ob.border)
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: Ob.border))
    }

    private var divider: some View { Hairline().padding(.top, 2).padding(.bottom, 12) }

    /// "Opacity" with the value as "90%", and the slider in 2% steps (TickFrequency 0.02, snapped).
    private func opacity(_ value: Binding<Double>, name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Opacity").font(Ob.sans(Ob.body))
                Spacer()
                Text(Fmt.percent(value.wrappedValue)).font(Ob.mono(12))
            }
            // TickFrequency 0.02 with snapping (from the minimum, 0.3), no ticks drawn; the Fluent slider in ink.
            FluentSlider(value: value, range: 0.3...1, step: 0.02)
                .padding(.top, 6).padding(.bottom, 10)
                .accessibilityLabel(name)
        }
    }

    private func position(_ name: String) -> some View {
        HStack {
            Text("Position").font(Ob.sans(Ob.body))
            Spacer()
            Text(name).font(Ob.sans(12)).foregroundStyle(ob.muted)
        }
    }

    /// The pill over placeholder text: a muted title bar and five track lines, the pill at the bottom centre, at the
    /// slider's opacity, with the active profile's name as it is written.
    private var overlayPreview: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(ob.muted).frame(width: 120, height: 7)
                ForEach(Array([0, 30, 10, 50, 20].enumerated()), id: \.offset) { i, right in
                    RoundedRectangle(cornerRadius: 2).fill(ob.muted).frame(height: 5)
                        .padding(.top, i == 0 ? 12 : 8).padding(.trailing, CGFloat(right))
                }
            }
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 0, trailing: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Padding 16,0 inside the pill's 1 px line; a name too long for the preview runs on and is cut, no "…".
            HStack(spacing: 0) {
                Circle().fill(Color(hex: 0xFF4636)).frame(width: 8, height: 8)
                Text("0:07").font(Ob.mono(12)).foregroundStyle(Color(hex: 0xE8E7E3)).padding(.leading, 10)
                Text(model.activeProfile.name).font(Ob.mono(11)).foregroundStyle(Color(hex: 0xE8E7E3, alpha: 0xB8 / 255.0))
                    .padding(.leading, 12)
            }
            .noWrap()
            .padding(.horizontal, 16 + Ob.border).frame(height: 40)
            .background(Capsule().fill(Color(hex: 0x0D0D0C, alpha: model.settings.overlayOpacity)))
            .overlay(Capsule().strokeBorder(Color(hex: 0xFFFFFF, alpha: 0x1F / 255.0), lineWidth: 1))
            .padding(.bottom, 22)
        }
        .background(ob.subtle)
    }
}
