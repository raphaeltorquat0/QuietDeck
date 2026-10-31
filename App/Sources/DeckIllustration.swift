import DeckRemote
import SwiftUI

/// Silhueta do console, desenhada do zero para o app.
struct DeckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: r, cornerSize: CGSize(width: r.height * 0.34, height: r.height * 0.34), style: .continuous)
        return p
    }
}

/// Steam Deck vetorial. `screen` desenha o conteúdo da tela: indicadores na Visão geral, menus no wizard.
struct DeckIllustration<Screen: View>: View {
    var highlightSteam = false
    @ViewBuilder var screen: Screen
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                DeckShape()
                    .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                    .overlay(DeckShape().stroke(.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)

                RoundedRectangle(cornerRadius: h * 0.025)
                    .fill(.black)
                    .overlay { screen.clipShape(RoundedRectangle(cornerRadius: h * 0.025)) }
                    .frame(width: w * 0.58, height: h * 0.74)

                side(w: w, h: h, x: -0.395)
                side(w: w, h: h, x: 0.395)

                Circle()
                    .fill(highlightSteam ? Color.accentColor : Color(white: 0.28))
                    .frame(width: w * 0.022)
                    .scaleEffect(highlightSteam && pulse ? 1.5 : 1)
                    .offset(x: -w * 0.34, y: h * 0.40)
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(2.45, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
        }
    }

    /// Analógico, botões e trackpad de um lado.
    private func side(w: CGFloat, h: CGFloat, x: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.07)).overlay(Circle().fill(Color(white: 0.17)).padding(w * 0.012))
                .frame(width: w * 0.075).offset(y: -h * 0.27)
            RoundedRectangle(cornerRadius: w * 0.012).fill(Color(white: 0.15))
                .frame(width: w * 0.092, height: w * 0.092).offset(y: h * 0.24)
            HStack(spacing: w * 0.012) {
                ForEach(0..<2, id: \.self) { _ in Circle().fill(Color(white: 0.3)).frame(width: w * 0.017) }
            }
            .offset(y: -h * 0.03)
        }
        .offset(x: w * x)
    }
}
