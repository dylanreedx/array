import Foundation

public struct LanguageServerRecipe: Codable, Equatable, Sendable {
    public enum Installer: Codable, Equatable, Sendable {
        case npm(package: String, version: String, executable: String)
        case go(module: String, version: String, executable: String)
        case archive(url: URL, sha256: String, executable: String)
    }

    public var id: String
    public var displayName: String
    public var languages: [String]
    public var fileExtensions: [String]
    public var executableNames: [String]
    public var arguments: [String]
    public var installer: Installer?

    public init(id: String, displayName: String, languages: [String], fileExtensions: [String], executableNames: [String], arguments: [String] = [], installer: Installer? = nil) {
        self.id = id; self.displayName = displayName; self.languages = languages
        self.fileExtensions = fileExtensions; self.executableNames = executableNames
        self.arguments = arguments; self.installer = installer
    }
}

public enum LanguageServerCatalog {
    public static let builtIns: [LanguageServerRecipe] = [
        .init(id: "typescript", displayName: "TypeScript Language Server", languages: ["typescript", "javascript"], fileExtensions: ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"], executableNames: ["typescript-language-server"], arguments: ["--stdio"], installer: .npm(package: "typescript-language-server", version: "4.3.4", executable: "typescript-language-server")),
        .init(id: "python", displayName: "Pyright", languages: ["python"], fileExtensions: ["py", "pyi"], executableNames: ["pyright-langserver"], arguments: ["--stdio"], installer: .npm(package: "pyright", version: "1.1.405", executable: "pyright-langserver")),
        .init(id: "css", displayName: "CSS Language Server", languages: ["css", "scss", "less"], fileExtensions: ["css", "scss", "less"], executableNames: ["vscode-css-language-server"], arguments: ["--stdio"], installer: .npm(package: "vscode-langservers-extracted", version: "4.10.0", executable: "vscode-css-language-server")),
        .init(id: "html", displayName: "HTML Language Server", languages: ["html"], fileExtensions: ["html", "htm"], executableNames: ["vscode-html-language-server"], arguments: ["--stdio"], installer: .npm(package: "vscode-langservers-extracted", version: "4.10.0", executable: "vscode-html-language-server")),
        .init(id: "json", displayName: "JSON Language Server", languages: ["json", "jsonc"], fileExtensions: ["json", "jsonc"], executableNames: ["vscode-json-language-server"], arguments: ["--stdio"], installer: .npm(package: "vscode-langservers-extracted", version: "4.10.0", executable: "vscode-json-language-server")),
        .init(id: "yaml", displayName: "YAML Language Server", languages: ["yaml"], fileExtensions: ["yaml", "yml"], executableNames: ["yaml-language-server"], arguments: ["--stdio"], installer: .npm(package: "yaml-language-server", version: "1.18.0", executable: "yaml-language-server")),
        .init(id: "bash", displayName: "Bash Language Server", languages: ["shellscript"], fileExtensions: ["sh", "bash", "zsh"], executableNames: ["bash-language-server"], arguments: ["start"], installer: .npm(package: "bash-language-server", version: "5.6.0", executable: "bash-language-server")),
        .init(id: "swift", displayName: "SourceKit-LSP", languages: ["swift"], fileExtensions: ["swift"], executableNames: ["sourcekit-lsp"]),
        .init(id: "rust", displayName: "rust-analyzer", languages: ["rust"], fileExtensions: ["rs"], executableNames: ["rust-analyzer"]),
        .init(id: "go", displayName: "gopls", languages: ["go"], fileExtensions: ["go"], executableNames: ["gopls"], installer: .go(module: "golang.org/x/tools/gopls", version: "v0.20.0", executable: "gopls")),
        .init(id: "clangd", displayName: "clangd", languages: ["c", "cpp", "objective-c", "objective-cpp"], fileExtensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm"], executableNames: ["clangd"])
    ]

    public static func recipe(forFileURL url: URL) -> LanguageServerRecipe? {
        let ext = url.pathExtension.lowercased()
        return builtIns.first { $0.fileExtensions.contains(ext) }
    }
}
