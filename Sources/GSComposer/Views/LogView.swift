import SwiftUI

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ログ").font(.caption.bold())
                Spacer()
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.logLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.isError ? Color.red : line.isCommand ? Color.accentColor : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.logLines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
