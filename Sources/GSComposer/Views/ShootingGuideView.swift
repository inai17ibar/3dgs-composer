import SwiftUI

/// How to film/photograph a subject so COLMAP can register every view and the splats come out level.
struct ShootingGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("撮影ガイド").font(.title2.bold())

                    HStack(alignment: .top, spacing: 24) {
                        diagram(title: "立ち位置（真上から）", caption: "被写体から同じ距離を保ち、少しずつ横に移動しながら一周します。") {
                            TopDownDiagram()
                        }
                        diagram(title: "高さ（横から）", caption: "低め・目線・見下ろしの 3 段で一周ずつ撮ると、上面や下側まで埋まります。") {
                            SideDiagram()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        tip("arrow.triangle.2.circlepath", "一周の目安",
                            "写真なら 1 周 24〜36 枚（10〜15° ずつ）。動画ならゆっくり 1 周 30 秒以上かけ、3 段で 1〜2 分。")
                        tip("square.on.square", "重なりを残す",
                            "隣り合う写真どうしが 6〜7 割重なるようにします。急に大きく移動すると位置合わせが途切れます。")
                        tip("iphone", "カメラを傾けない",
                            "縦持ち・横持ちはどちらかに統一し、途中で回転させないでください。上下の向きは写真の向きから推定するため、傾くと仕上がりが傾きます。")
                        tip("figure.stand", "被写体は動かさない",
                            "回るのは撮影者です。ターンテーブルで被写体を回すと背景と矛盾して失敗します。")
                        tip("sun.max", "明るく、ブレなく",
                            "明るい場所でシャッター速度を確保し、ズームは固定します。オートフォーカス・露出が大きく変わらないよう注意します。")
                        tip("exclamationmark.triangle", "苦手なもの",
                            "鏡・ガラス・光沢の強い面、無地の壁や床だけの背景、動く人や木の葉は再構成が崩れやすくなります。")
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 640)
    }

    private func diagram<Content: View>(title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
                .frame(width: 270, height: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 270)
    }

    private func tip(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Camera stations on a ring around the subject, each facing the centre.
private struct TopDownDiagram: View {
    private let stations = 12
    private let radius: CGFloat = 80

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(c)
                // Direction of travel.
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .position(x: c.x + radius * 0.55, y: c.y - radius * 0.55)
                Image(systemName: "cube.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .position(c)
                ForEach(0..<stations, id: \.self) { i in
                    let angle = 2 * Double.pi * Double(i) / Double(stations) - .pi / 2
                    Image(systemName: "video.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(i == 0 ? Color.accentColor : Color.primary)
                        .rotationEffect(.radians(angle + .pi))
                        .position(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
                }
                Text("開始").font(.caption2).foregroundStyle(Color.accentColor)
                    .position(x: c.x, y: c.y - radius - 16)
            }
        }
    }
}

/// Three camera heights (low, eye level, high looking down) on both sides of the subject.
private struct SideDiagram: View {
    private let rings: [(label: String, height: CGFloat)] = [("見下ろし", 150), ("目線", 90), ("低め", 40)]

    var body: some View {
        GeometryReader { geo in
            let ground = geo.size.height - 30
            let subject = CGPoint(x: geo.size.width / 2, y: ground - 18)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 16, y: ground))
                    p.addLine(to: CGPoint(x: geo.size.width - 16, y: ground))
                }
                .stroke(.secondary, lineWidth: 1)
                Image(systemName: "cube.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .position(subject)
                ForEach(rings.indices, id: \.self) { i in
                    let y = ground - rings[i].height
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        let cam = CGPoint(x: subject.x + side * 95, y: y)
                        Path { p in
                            p.move(to: cam)
                            p.addLine(to: subject)
                        }
                        .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        Image(systemName: "video.fill")
                            .font(.system(size: 13))
                            .rotationEffect(.radians(atan2(subject.y - cam.y, subject.x - cam.x)))
                            .position(cam)
                    }
                    // Above the left camera: its sight line runs down-right, so this spot stays clear.
                    Text(rings[i].label).font(.caption2).foregroundStyle(.secondary)
                        .position(x: subject.x - 95, y: y - 15)
                }
            }
        }
    }
}
