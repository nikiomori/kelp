import WorkbenchKit

/// Kelp's own languages: the files of each, its language servers and its run, test and format commands. Data only: a
/// server is started for the first file opened, when it's installed; an extension's language with the same `id`
/// replaces one.
enum Languages {
    private typealias Server = LanguageSpec.Server

    static let all: [LanguageSpec] = code + data

    private static let typescript = Server(
        command: "typescript-language-server", args: ["--stdio"],
        install: "npm i -g typescript-language-server typescript")
    private static let clangd = Server(command: "clangd", install: "xcode-select --install")

    private static let code: [LanguageSpec] = [
        LanguageSpec(
            id: "swift", extensions: ["swift"], server: .init(command: "xcrun", args: ["sourcekit-lsp"]),
            format: "swift format -"),
        LanguageSpec(id: "typescript", extensions: ["ts"], server: typescript),
        LanguageSpec(id: "typescriptreact", extensions: ["tsx"], server: typescript),
        LanguageSpec(id: "javascript", extensions: ["js"], server: typescript, run: "node ${file}"),
        LanguageSpec(id: "javascriptreact", extensions: ["jsx"], server: typescript),
        // ruff beside pyright: its warnings and fixes, when it's installed.
        LanguageSpec(
            id: "python", extensions: ["py"],
            server: .init(command: "pyright-langserver", args: ["--stdio"], install: "npm i -g pyright"),
            servers: [.init(command: "ruff", args: ["server"], install: "brew install ruff", optional: true)],
            run: "python3 ${file}", test: "python3 -m pytest ${file} -k ${symbol}", format: "ruff format -"),
        // The file's package, so a main split over several files runs too.
        LanguageSpec(
            id: "go", extensions: ["go"],
            server: .init(command: "gopls", install: "go install golang.org/x/tools/gopls@latest"),
            run: "cd ${dir} && go run .", test: "cd ${dir} && go test -run ${symbol} .", format: "gofmt"),
        // From stdin rustfmt can't read Cargo.toml's edition, and 2015's parser rejects async fn.
        LanguageSpec(
            id: "rust", extensions: ["rs"],
            server: .init(command: "rust-analyzer", install: "rustup component add rust-analyzer"),
            test: "cargo test ${symbol}", format: "rustfmt --edition 2021"),
        LanguageSpec(
            id: "c", extensions: ["c", "h"], server: clangd, format: "clang-format --assume-filename=${file}"),
        LanguageSpec(
            id: "cpp", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx"], server: clangd,
            format: "clang-format --assume-filename=${file}"),
        LanguageSpec(id: "objective-c", extensions: ["m"], server: clangd),
        LanguageSpec(id: "objective-cpp", extensions: ["mm"], server: clangd),
        LanguageSpec(
            id: "ruby", extensions: ["rb"], fileNames: ["Gemfile", "Rakefile"],
            server: .init(command: "ruby-lsp", install: "gem install ruby-lsp"), run: "ruby ${file}"),
        LanguageSpec(
            id: "php", extensions: ["php"],
            server: .init(command: "intelephense", args: ["--stdio"], install: "npm i -g intelephense"),
            run: "php ${file}"),
        LanguageSpec(id: "java", extensions: ["java"], server: .init(command: "jdtls", install: "brew install jdtls")),
        LanguageSpec(
            id: "kotlin", extensions: ["kt", "kts"],
            server: .init(command: "kotlin-language-server", install: "brew install kotlin-language-server")),
        LanguageSpec(
            id: "csharp", extensions: ["cs"],
            server: .init(command: "csharp-ls", install: "dotnet tool install --global csharp-ls")),
        LanguageSpec(
            id: "lua", extensions: ["lua"],
            server: .init(command: "lua-language-server", install: "brew install lua-language-server"),
            run: "lua ${file}", format: "stylua -"),
        LanguageSpec(
            id: "shellscript", extensions: ["sh", "bash"],
            server: .init(
                command: "bash-language-server", args: ["start"], install: "npm i -g bash-language-server"),
            run: "bash ${file}", format: "shfmt -"),
        LanguageSpec(
            id: "zig", extensions: ["zig"], server: .init(command: "zls", install: "brew install zls"),
            run: "zig run ${file}", format: "zig fmt --stdin"),
        LanguageSpec(
            id: "elixir", extensions: ["ex", "exs"],
            server: .init(command: "elixir-ls", install: "brew install elixir-ls"), format: "mix format -"),
        LanguageSpec(
            id: "dart", extensions: ["dart"], server: .init(command: "dart", args: ["language-server"]),
            run: "dart run ${file}"),
        LanguageSpec(
            id: "haskell", extensions: ["hs"],
            server: .init(command: "haskell-language-server-wrapper", args: ["--lsp"], install: "ghcup install hls")),
        LanguageSpec(
            id: "ocaml", extensions: ["ml", "mli"],
            server: .init(command: "ocamllsp", install: "opam install ocaml-lsp-server")),
        LanguageSpec(
            id: "scala", extensions: ["scala", "sbt"], server: .init(command: "metals", install: "cs install metals")),
        LanguageSpec(id: "gleam", extensions: ["gleam"], server: .init(command: "gleam", args: ["lsp"])),
        LanguageSpec(
            id: "terraform", extensions: ["tf", "tfvars"],
            server: .init(
                command: "terraform-ls", args: ["serve"], install: "brew install hashicorp/tap/terraform-ls"),
            format: "terraform fmt -")
    ]

    // Files every project has: their servers are optional, so one that isn't installed is nobody's banner.
    private static let web = "npm i -g vscode-langservers-extracted"
    private static let json = Server(
        command: "vscode-json-language-server", args: ["--stdio"], install: web, optional: true)
    private static let css = Server(
        command: "vscode-css-language-server", args: ["--stdio"], install: web, optional: true)

    private static let data: [LanguageSpec] = [
        LanguageSpec(id: "json", extensions: ["json"], server: json),
        LanguageSpec(id: "jsonc", extensions: ["jsonc"], server: json),
        LanguageSpec(
            id: "html", extensions: ["html", "htm"],
            server: .init(command: "vscode-html-language-server", args: ["--stdio"], install: web, optional: true)),
        LanguageSpec(id: "css", extensions: ["css"], server: css),
        LanguageSpec(id: "scss", extensions: ["scss"], server: css),
        LanguageSpec(id: "less", extensions: ["less"], server: css),
        LanguageSpec(
            id: "yaml", extensions: ["yaml", "yml"],
            server: .init(
                command: "yaml-language-server", args: ["--stdio"], install: "npm i -g yaml-language-server",
                optional: true)),
        LanguageSpec(
            id: "toml", extensions: ["toml"],
            server: .init(command: "taplo", args: ["lsp", "stdio"], install: "brew install taplo", optional: true)),
        LanguageSpec(
            id: "dockerfile", extensions: ["dockerfile"], fileNames: ["Dockerfile"],
            server: .init(
                command: "docker-langserver", args: ["--stdio"],
                install: "npm i -g dockerfile-language-server-nodejs", optional: true))
    ]
}
