import Foundation

/// Tudo que vira linha de comando no Deck passa por aqui: nomes de jogo têm apóstrofo e espaço.
public enum Shell {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
