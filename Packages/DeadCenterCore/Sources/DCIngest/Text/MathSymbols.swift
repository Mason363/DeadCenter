import Foundation

/// Unicode equivalents for TeX math commands and characters.
enum MathSymbols {
    /// How a symbol is spaced, as in TeX: ordinary atoms touch, binary operators and relations get
    /// spaces around them, large operators and function names a space before their operand.
    enum Kind {
        case ordinary, binary, relation, punctuation, opening, closing, largeOperator, function, space, text
    }

    static func table(_ pairs: [(String, String)]) -> [String: String] {
        Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    static let greek = table([
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ϵ"), ("varepsilon", "ε"),
        ("zeta", "ζ"), ("eta", "η"), ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"),
        ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("omicron", "ο"), ("pi", "π"), ("varpi", "ϖ"),
        ("rho", "ρ"), ("varrho", "ϱ"), ("sigma", "σ"), ("varsigma", "ς"), ("tau", "τ"), ("upsilon", "υ"),
        ("phi", "ϕ"), ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"), ("Pi", "Π"),
        ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
        ("digamma", "ϝ"), ("varkappa", "ϰ"),
    ])

    static let binary = table([
        ("times", "×"), ("cdot", "·"), ("pm", "±"), ("mp", "∓"), ("div", "÷"), ("ast", "∗"), ("star", "⋆"),
        ("circ", "∘"), ("bullet", "•"), ("cup", "∪"), ("cap", "∩"), ("setminus", "∖"), ("smallsetminus", "∖"),
        ("oplus", "⊕"), ("ominus", "⊖"), ("otimes", "⊗"), ("oslash", "⊘"), ("odot", "⊙"), ("wedge", "∧"),
        ("land", "∧"), ("vee", "∨"), ("lor", "∨"), ("sqcup", "⊔"), ("sqcap", "⊓"), ("uplus", "⊎"), ("amalg", "⨿"),
        ("dagger", "†"), ("ddagger", "‡"), ("wr", "≀"), ("diamond", "⋄"), ("bigtriangleup", "△"),
        ("bigtriangledown", "▽"), ("triangleleft", "◁"), ("triangleright", "▷"), ("cdotp", "·"),
    ])

    static let relation = table([
        ("le", "≤"), ("leq", "≤"), ("ge", "≥"), ("geq", "≥"), ("leqslant", "⩽"), ("geqslant", "⩾"), ("ne", "≠"),
        ("neq", "≠"), ("approx", "≈"), ("sim", "∼"), ("simeq", "≃"), ("cong", "≅"), ("equiv", "≡"), ("propto", "∝"),
        ("ll", "≪"), ("gg", "≫"), ("prec", "≺"), ("succ", "≻"), ("preceq", "⪯"), ("succeq", "⪰"),
        ("in", "∈"), ("notin", "∉"), ("ni", "∋"), ("subset", "⊂"), ("subseteq", "⊆"), ("supset", "⊃"),
        ("supseteq", "⊇"), ("subsetneq", "⊊"), ("supsetneq", "⊋"), ("sqsubseteq", "⊑"), ("sqsupseteq", "⊒"),
        ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←"), ("gets", "←"), ("leftrightarrow", "↔"),
        ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("Leftrightarrow", "⇔"), ("implies", "⟹"), ("impliedby", "⟸"),
        ("iff", "⟺"), ("mapsto", "↦"), ("longrightarrow", "⟶"), ("longleftarrow", "⟵"), ("longmapsto", "⟼"),
        ("Longrightarrow", "⟹"), ("Longleftarrow", "⟸"), ("Longleftrightarrow", "⟺"), ("uparrow", "↑"),
        ("downarrow", "↓"), ("updownarrow", "↕"), ("Uparrow", "⇑"), ("Downarrow", "⇓"), ("nearrow", "↗"),
        ("searrow", "↘"), ("hookrightarrow", "↪"), ("hookleftarrow", "↩"), ("rightleftharpoons", "⇌"),
        ("perp", "⊥"), ("parallel", "∥"), ("mid", "∣"), ("nmid", "∤"), ("vdash", "⊢"), ("dashv", "⊣"),
        ("models", "⊨"), ("asymp", "≍"), ("doteq", "≐"), ("triangleq", "≜"), ("coloneqq", "≔"),
        ("colon", ":"), ("lt", "<"), ("gt", ">"), ("nleq", "≰"), ("ngeq", "≱"), ("nsim", "≁"), ("ncong", "≇"),
        ("lesssim", "≲"), ("gtrsim", "≳"), ("therefore", "∴"), ("because", "∵"),
    ])

    static let ordinary = table([
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"),
        ("neg", "¬"), ("lnot", "¬"), ("emptyset", "∅"), ("varnothing", "∅"), ("hbar", "ℏ"), ("hslash", "ℏ"),
        ("ell", "ℓ"), ("Re", "ℜ"), ("Im", "ℑ"), ("aleph", "ℵ"), ("beth", "ℶ"), ("wp", "℘"), ("angle", "∠"),
        ("measuredangle", "∡"), ("triangle", "△"), ("square", "□"), ("Box", "□"), ("blacksquare", "■"),
        ("degree", "°"), ("prime", "′"), ("dprime", "″"), ("top", "⊤"), ("bot", "⊥"), ("checkmark", "✓"),
        ("ldots", "…"), ("dots", "…"), ("dotsc", "…"), ("dotsb", "⋯"), ("cdots", "⋯"), ("vdots", "⋮"),
        ("ddots", "⋱"), ("sharp", "♯"), ("flat", "♭"), ("natural", "♮"), ("clubsuit", "♣"),
        ("diamondsuit", "♢"), ("heartsuit", "♡"), ("spadesuit", "♠"), ("vert", "|"), ("Vert", "‖"),
        ("lvert", "|"), ("rvert", "|"), ("lVert", "‖"), ("rVert", "‖"), ("backslash", "\\"), ("imath", "ı"),
        ("jmath", "ȷ"), ("mho", "℧"), ("complement", "∁"), ("surd", "√"), ("S", "§"), ("P", "¶"),
        ("copyright", "©"), ("pounds", "£"), ("euro", "€"), ("dag", "†"), ("ddag", "‡"),
    ])

    static let opening = table([
        ("langle", "⟨"), ("lceil", "⌈"), ("lfloor", "⌊"), ("lbrace", "{"), ("lbrack", "["), ("lparen", "("),
    ])

    static let closing = table([
        ("rangle", "⟩"), ("rceil", "⌉"), ("rfloor", "⌋"), ("rbrace", "}"), ("rbrack", "]"), ("rparen", ")"),
    ])

    static let largeOperators = table([
        ("sum", "∑"), ("prod", "∏"), ("coprod", "∐"), ("int", "∫"), ("iint", "∬"), ("iiint", "∭"),
        ("oint", "∮"), ("bigcup", "⋃"), ("bigcap", "⋂"), ("bigoplus", "⨁"), ("bigotimes", "⨂"),
        ("bigvee", "⋁"), ("bigwedge", "⋀"), ("bigsqcup", "⨆"), ("biguplus", "⨄"), ("bigodot", "⨀"),
    ])

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "dim", "ker",
        "arg", "gcd", "deg", "hom", "Pr", "mod", "lcm", "sgn", "tr", "rank", "argmax", "argmin", "Var", "Cov",
    ]

    /// Combining marks for accents.
    static let accents = table([
        ("hat", "\u{302}"), ("widehat", "\u{302}"), ("bar", "\u{304}"), ("overline", "\u{305}"), ("vec", "\u{20D7}"),
        ("overrightarrow", "\u{20D7}"), ("dot", "\u{307}"), ("ddot", "\u{308}"), ("tilde", "\u{303}"),
        ("widetilde", "\u{303}"), ("acute", "\u{301}"), ("grave", "\u{300}"), ("breve", "\u{306}"),
        ("check", "\u{30C}"), ("mathring", "\u{30A}"),
    ])

    /// Commands that only change style: their argument is kept.
    static let styleCommands: Set<String> = [
        "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal", "textup", "textsl", "textsc",
        "emph", "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "mathnormal", "boldsymbol", "bm", "pmb",
        "mbox", "hbox", "mathcal", "mathscr", "mathfrak", "underline", "underbrace", "overbrace", "mathop",
        "mathord", "mathbin", "mathrel", "displaylines", "boxed", "fbox", "cancel", "bcancel", "xcancel", "smash",
        "mathstrut", "ensuremath", "textstyle", "mathchoice", "mathclap", "mathllap", "mathrlap",
    ]

    /// Commands that take an argument that should not be read.
    static let discardedWithArgument: Set<String> = [
        "label", "tag", "hspace", "vspace", "phantom", "hphantom", "vphantom", "color", "ref", "eqref", "cite",
        "nonumber", "notag", "kern", "mkern", "mspace", "hskip", "vskip",
    ]

    /// Commands without arguments that produce nothing.
    static let ignored: Set<String> = [
        "displaystyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "nonumber", "notag", "left",
        "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl",
        "Biggr", "bigm", "Bigm", "relax", "allowbreak", "nobreak", "strut", "centering", "hline", "noindent",
        "par", "newline", "linebreak", "displaybreak", "quad", "qquad", "enspace", "thinspace", "medspace",
        "thickspace", "negthinspace",
    ]

    static let doubleStruck = table([
        ("N", "ℕ"), ("Z", "ℤ"), ("Q", "ℚ"), ("R", "ℝ"), ("C", "ℂ"), ("P", "ℙ"), ("H", "ℍ"), ("E", "𝔼"),
        ("F", "𝔽"), ("1", "𝟙"),
    ])

    static let vulgarFractions = table([
        ("1/2", "½"), ("1/3", "⅓"), ("2/3", "⅔"), ("1/4", "¼"), ("3/4", "¾"), ("1/5", "⅕"), ("2/5", "⅖"),
        ("3/5", "⅗"), ("4/5", "⅘"), ("1/6", "⅙"), ("5/6", "⅚"), ("1/8", "⅛"), ("3/8", "⅜"), ("5/8", "⅝"),
        ("7/8", "⅞"), ("1/7", "⅐"), ("1/9", "⅑"), ("1/10", "⅒"),
    ])

    static let superscripts: [Character: Character] = Dictionary(Array(zip(
        "0123456789+-−=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVWβγδθιφχ∗*",
        "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵝᵞᵟᶿᶥᵠᵡ**")), uniquingKeysWith: { a, _ in a })

    static let subscripts: [Character: Character] = Dictionary(Array(zip(
        "0123456789+-−=()aehijklmnoprstuvxβγρφχ",
        "₀₁₂₃₄₅₆₇₈₉₊₋₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ")), uniquingKeysWith: { a, _ in a })

    /// The spacing class of a plain character in math mode.
    static func kind(of character: Character) -> Kind {
        switch character {
        case "+", "-", "−", "±", "×", "÷", "·", "∗": .binary
        case "=", "<", ">", "≤", "≥", "≠", "≈", "→", "←", "∈", ":": .relation
        case ",", ";": .punctuation
        case "(", "[": .opening
        case ")", "]", "!", "?": .closing
        default: .ordinary
        }
    }
}
