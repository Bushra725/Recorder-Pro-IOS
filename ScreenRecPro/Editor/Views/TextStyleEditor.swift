import SwiftUI

/// Port of Android's `edit/TextStyleSheet.kt`: Keyboard · Font · Colour
/// (Text / Border / Background / Shadow) · Layout. Shared by the video studio
/// and the photo editor through `TextStyleTarget`.
@MainActor
protocol TextStyleTarget: ObservableObject {
    func updateText(_ id: Int64, staged: Bool, _ transform: (inout TextItem) -> Void)
    func commitStaged()
    func deleteText(_ id: Int64)
}

extension StudioViewModel: TextStyleTarget {}

struct TextStyleEditor<Target: TextStyleTarget>: View {
    @ObservedObject var vm: Target
    let item: TextItem

    enum Tab: String, CaseIterable { case keyboard, font, color, layout }
    enum ColorTarget: String, CaseIterable { case text, border, background, shadow }

    @State private var tab: Tab = .keyboard
    @State private var colorTarget: ColorTarget = .text
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                tabButton(.keyboard, "keyboard", L("text_style_keyboard"))
                tabButton(.font, "textformat", L("text_style_text"))
                tabButton(.color, "paintpalette", L("text_style_color"))
                tabButton(.layout, "text.alignleft", L("text_style_layout"))
                Spacer()
                Button { vm.deleteText(item.id) } label: { Image(systemName: "trash") }
                    .foregroundStyle(Brand.record)
            }
            switch tab {
            case .keyboard: keyboard
            case .font: fonts
            case .color: colors
            case .layout: layout
            }
        }
        .onAppear { draft = item.text }
        .onChange(of: item.id) { _ in draft = item.text }
    }

    private func tabButton(_ t: Tab, _ icon: String, _ label: String) -> some View {
        Button { tab = t } label: {
            Image(systemName: icon)
                .frame(width: 38, height: 32)
                .background(tab == t ? Color.white.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }

    private func update(staged: Bool = false, _ t: (inout TextItem) -> Void) {
        vm.updateText(item.id, staged: staged, t)
    }

    // MARK: tabs

    private var keyboard: some View {
        HStack {
            TextField(L("your_text"), text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(.black)
            Button(L("done")) {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { update { $0.text = t } }
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private var fonts: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TextRenderer.fonts) { f in
                        Button { update { $0.fontID = f.id } } label: {
                            Text(f.label)
                                .font(Font(TextRenderer.font(f.id, size: 15, bold: item.bold) as CTFont))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(item.fontID == f.id ? Color.white : Color.white.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(item.fontID == f.id ? .black : .white)
                        }
                    }
                }
            }
            Toggle(L("font_bold"), isOn: Binding(get: { item.bold }, set: { v in update { $0.bold = v } }))
                .tint(Brand.accent)
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $colorTarget) {
                Text(L("text_style_text")).tag(ColorTarget.text)
                Text(L("text_style_border")).tag(ColorTarget.border)
                Text(L("text_style_background")).tag(ColorTarget.background)
                Text(L("text_style_shadow")).tag(ColorTarget.shadow)
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if colorTarget != .text {
                        swatch(nil)
                    }
                    ForEach(Brand.editSwatches, id: \.self) { swatch($0) }
                }
            }

            switch colorTarget {
            case .text:
                StagedSlider(label: L("text_style_opacity"), value: item.opacity, range: 0.1...1,
                             format: { "\(Int($0 * 100))%" },
                             onChange: { v in update(staged: true) { $0.opacity = v } }, onCommit: { vm.commitStaged() })
            case .border:
                StagedSlider(label: L("text_style_size"), value: item.outlineWidth, range: 0.02...0.4,
                             format: { "\(Int($0 * 100))" },
                             onChange: { v in update(staged: true) { $0.outlineWidth = v; $0.outline = true } },
                             onCommit: { vm.commitStaged() })
            case .background:
                StagedSlider(label: L("text_style_opacity"), value: item.bgOpacity, range: 0.1...1,
                             format: { "\(Int($0 * 100))%" },
                             onChange: { v in update(staged: true) { $0.bgOpacity = v } }, onCommit: { vm.commitStaged() })
            case .shadow:
                StagedSlider(label: L("text_style_blur"), value: item.shadowBlur, range: 0...24,
                             onChange: { v in update(staged: true) { $0.shadowBlur = v; $0.shadow = true } },
                             onCommit: { vm.commitStaged() })
                StagedSlider(label: L("text_style_offset_x"), value: item.shadowDX, range: -20...20,
                             onChange: { v in update(staged: true) { $0.shadowDX = v; $0.shadow = true } },
                             onCommit: { vm.commitStaged() })
                StagedSlider(label: L("text_style_offset_y"), value: item.shadowDY, range: -20...20,
                             onChange: { v in update(staged: true) { $0.shadowDY = v; $0.shadow = true } },
                             onCommit: { vm.commitStaged() })
            }
        }
    }

    private func swatch(_ argb: UInt32?) -> some View {
        let current: UInt32? = {
            switch colorTarget {
            case .text: return item.colorARGB
            case .border: return item.outline ? item.outlineARGB | 0xFF000000 : nil
            case .background: return (item.bgARGB >> 24) != 0 ? item.bgARGB | 0xFF000000 : nil
            case .shadow: return item.shadow ? item.shadowARGB | 0xFF000000 : nil
            }
        }()
        let selected = (argb.map { $0 | 0xFF000000 }) == current
        return Button {
            SoundFx.tick()
            update { t in
                switch colorTarget {
                case .text: t.colorARGB = argb ?? 0xFFFFFFFF
                case .border:
                    t.outline = argb != nil
                    if let argb { t.outlineARGB = argb }
                case .background: t.bgARGB = argb ?? 0
                case .shadow:
                    t.shadow = argb != nil
                    if let argb { t.shadowARGB = (argb & 0x00FFFFFF) | 0xB4000000 }
                }
            }
        } label: {
            ZStack {
                if let argb {
                    Circle().fill(Color(UIColor(argb: argb)))
                } else {
                    Circle().fill(Color.white.opacity(0.1))
                    Image(systemName: "nosign").font(.caption).foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(selected ? Brand.accent : Color.white.opacity(0.3), lineWidth: selected ? 3 : 1))
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("text_style_align"), selection: Binding(get: { item.align }, set: { v in update { $0.align = v } })) {
                Image(systemName: "text.alignleft").tag(TextItem.Align.left)
                Image(systemName: "text.aligncenter").tag(TextItem.Align.center)
                Image(systemName: "text.alignright").tag(TextItem.Align.right)
            }
            .pickerStyle(.segmented)
            StagedSlider(label: L("text_style_size"), value: item.size, range: 0.015...0.3,
                         format: { "\(Int($0 * 1000))" },
                         onChange: { v in update(staged: true) { $0.size = v } }, onCommit: { vm.commitStaged() })
            StagedSlider(label: L("text_style_character"), value: item.letterSpacing, range: -0.05...0.5,
                         format: { String(format: "%.2f", $0) },
                         onChange: { v in update(staged: true) { $0.letterSpacing = v } }, onCommit: { vm.commitStaged() })
            StagedSlider(label: L("text_style_line"), value: item.lineSpacing, range: 0...1,
                         format: { String(format: "%.2f", $0) },
                         onChange: { v in update(staged: true) { $0.lineSpacing = v } }, onCommit: { vm.commitStaged() })
        }
    }
}
