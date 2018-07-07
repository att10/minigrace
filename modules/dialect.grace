#pragma ExtendedLineups
dialect "none"
import "standardGrace" as sg
import "errormessages" as errormessages
import "ast" as ast

inherit sg.methods

method methods {
    // This should be unnecessary, because it is inherited.
    // But the compiler gets confised and does not find it statically.
    prelude.clone(self)
}

// Checker error

def CheckerFailure is public = Exception.refine "CheckerFailure"
def DialectError is public = Exception.refine "DialectError"

// Helper Map

class entryFrom(key') to(value') is confidential {
    def key is public = key'
    var value is public := value'
}

class aMutableMap {

    def entries = []

    method isEmpty -> Boolean { size == 0 }

    method size -> Number { entries.size }

    method at(key) {
        atKey(key) do { value -> return value }

        NoSuchObject.raise "no key {key} in aMutableMap"
    }

    method at(key) put(value) -> Done {
        if (value.asString == "done") then {
            ProgrammingError.raise "mutableMap: attempting to put ‹done› at key {key}"
        }
        for(entries) do { entry ->
            if(entry.key == key) then {
                entry.value := value
                return done
            }
        }

        entries.push(entryFrom(key) to(value))
    }

    method keys -> List {
        def keys' = []

        for(entries) do { entry ->
            keys'.push(entry.key)
        }

        return keys'
    }

    method values -> List {
        def values' = []

        for(entries) do { entry ->
            values'.push(entry.value)
        }

        return values'
    }

    method containsKey(key) -> Boolean {
        atKey(key) do { _ -> return true }

        return false
    }

    method atKey(key) do(block) -> Done {
        atKey(key) do(block) else {}
        return
    }

    method atKey(key) do(block) else(block') {
        for(entries) do { entry ->
            if(entry.key == key) then {
                return block.apply(entry.value)
            }
        }

        return block'.apply
    }

    method asString -> String is override {
        if(isEmpty) then {
            return "\{\}"
        }

        var out := "\{"

        var once := false
        for(entries) do { entry ->
            if(once) then {
                out := "{out},"
            }
            out := "{out} {entry.key} => {entry.value}"
            once := true
        }

        return "{out} \}"
    }

}



// Rules

// The defined type rules.
def rules = []

// The cached type assignments.
def cache = aMutableMap

// Creates a new type rule.
method rule(block) -> Done {
    rules.push(block)
}


var currentLine := 0        // Will be updated with each node examined

method fail (message) {
    // short fail-with-message; gives source line only

    DialectError.raise (message) with (ast.line(currentLine) column 0)
}

method fail (message) at (rng:ast.Range) {
    // fail, using the source-file range rng for the error message
    // Note that, since ast.AstNode conforms to ast.Range, the second
    // argument can be an AstNode.

    DialectError.raise (message) with (rng)
}
method fail (message) from (startCol) to (endCol) {
    // fail, with a source range

    def rng = ast.start (ast.line(currentLine) column(startCol))
                  end (ast.line(currentLine) column(endCol))
    DialectError.raise (message) with (rng)
}

method fail(message) from (startCol) to (endCol) suggest (sugg) {
    // fail, with an object that contains a source range and a suggestion

    def o = object {
        inherit ast.start (ast.line(currentLine) column(startCol))
                end (ast.line(currentLine) column(endCol))
        def suggestions is public = [sugg]
    }
    DialectError.raise (message) with (o)
}

method fail (msg) when (pat) -> Done {
    // adds a rule the the list of active rules.  The rule will fail when
    // applied to a node x such that pat.match(x), and pat.apply(x) is true

    rule { x ->
        def mat = pat.match(x)
        if (mat && {mat.result}) then {
            fail(msg)
        }
    }
}

method createSuggestion {
    errormessages.suggestion.new
}

method when(pat)error(msg) {
    // alternate syntax for fail (msg) when (pat)

    fail(msg)when(pat)
}

// Scope

class stackOfKind(kind : String) is confidential {
    def stack is public = [aMutableMap]

    method at(name : String) put(value) -> Done {
        stack.last.at(name) put(value)
    }

    method find(name : String) butIfMissing(bl) {
        var i := stack.size
        while { i > 0 } do {
            stack.at(i).atKey(name) do { value ->
                return value
            }

            i := i - 1
        }

        return bl.apply
    }

}

def scope is public = object {
    def variables is public = stackOfKind("variable")
    def methods is public = stackOfKind("method")
    def types is public = stackOfKind("type")

    method size -> Number {
        variables.stack.size
    }

    method enter(bl) {
        variables.stack.push(aMutableMap)
        methods.stack.push(aMutableMap)
        types.stack.push(aMutableMap)

        def result = bl.apply

        variables.stack.pop
        methods.stack.pop
        types.stack.pop

        return result
    }

    method asString -> String is override {
        "scope<{size}>"
    }
}

method checkTypes(node) {
    node.accept(astVisitor)
}

method typeOf(node) {
    checkTypes(node)
    cache.atKey(node) do { value -> return value }
    DialectError.raise "cannot type non-expression {node}" with (node)
}

method runRules(node) {
    // apply all rules to node; returns the last SuccessfulMatch.
    // if there is no successful match, returns FailedMatch(node).
    cache.atKey(node) do { value -> return value }
    currentLine := node.line

    var result := FailedMatch.new(node)
    for (rules) do { each ->
        def matched = each.match(node)
        if(matched) then {
            result := matched.result
            if (result.asString == "done") then {
                ProgrammingError.raise
                    "rule.match(node) has result 'done' when rule is {each} and node = {node}"
            }
            cache.at(node) put(result)
        }
    }
    return result
}


// Type checker

// Checks the defined rules on the given AST.
method check(module) -> Done {
    // Runs the check on the module object.
    module.accept(astVisitor)
}

type AstNode = { kind -> String }

class aPatternMatchingNode(kind : String) -> Pattern {
    inherit BasicPattern.new

    method match(obj : Object) -> MatchResult {
        match(obj) case { node : AstNode ->
            if(kind == node.kind) then {
                SuccessfulMatch.new(node, [])
            } else {
                FailedMatch.new(node)
            }
        } case { _ ->
            FailedMatch.new(obj)
        }
    }
}

def If is public = aPatternMatchingNode "if"
def BlockLiteral is public = aPatternMatchingNode "block"
def MatchCase is public = aPatternMatchingNode "matchcase"
def TryCatch is public = aPatternMatchingNode "trycatch"
def Outer is public = aPatternMatchingNode "outer"
def MethodSignature is public = aPatternMatchingNode "methodtype"
def TypeLiteral is public = aPatternMatchingNode "typeliteral"
def TypeDeclaration is public = aPatternMatchingNode "typedec"
def TypeAnnotation is public = aPatternMatchingNode "dtype"
def Method is public = aPatternMatchingNode "method"
def Parameter is public = aPatternMatchingNode "parameter"
def Request is public = aPatternMatchingNode "call"
def Class is public = aPatternMatchingNode "class"
def ObjectLiteral is public = aPatternMatchingNode "object"
def ArrayLiteral is public = aPatternMatchingNode "array"
def Member is public = aPatternMatchingNode "member"
def Generic is public = aPatternMatchingNode "generic"
def Identifier is public = aPatternMatchingNode "identifier"
def OctetsLiteral is public = aPatternMatchingNode "octets"
def StringLiteral is public = aPatternMatchingNode "string"
def NumberLiteral is public = aPatternMatchingNode "num"
def Operator is public = aPatternMatchingNode "op"
def Bind is public = aPatternMatchingNode "bind"
def Def is public = aPatternMatchingNode "defdec"
def Var is public = aPatternMatchingNode "vardec"
def Import is public = aPatternMatchingNode "import"
def Dialect is public = aPatternMatchingNode "dialect"
def Return is public = aPatternMatchingNode "return"
def Inherit is public = aPatternMatchingNode "inherit"

// Special requests patterns.

class RequestOf(methodName:String) -> Pattern {

    inherit BasicPattern.new

    method match(obj:Object) -> MatchResult {
        match(obj) case { node:AstNode ->
            if (node.isCall && {node.canonicalName == methodName}) then {
                SuccessfulMatch.new(node, makeBindings(node))
            } else {
                FailedMatch.new(node)
            }
        } case { _ ->
            FailedMatch.new(obj)
        }
    }

    method makeBindings(node) { [] }
}

def WhileRequest is public = RequestOf "while(_)do(_)"
def ForRequest is public = RequestOf "for(_)do(_)"

method whileCond(node) {
    // answers the condition expression from node, which must be a
    // a callNode calling "while(_)do(_)"
    def sig = node.parts
    sig.first.args.first
}

method whileBody(node) {
    // answers the body expression from node, which must be a
    // a callNode calling "while(_)do(_)"
    def sig = node.parts
    sig.second.args.first
}

method forCollection(node) {
    // answers the collection expression from node, which must be a
    // a callNode calling "for(_)do(_)"
    def sig = node.parts
    sig.first.args.first
}

method forBody(node) {
    // answers the body expression from node, which must be a
    // a callNode calling "for(_)do(_)"
    def sig = node.parts
    sig.second.args.first
}

def astVisitor = object {
    inherit ast.baseVisitor

    method checkMatch(node) -> Boolean {
        runRules(node)
        return true
    }

    method visitIf(node) -> Boolean {
        checkMatch(node)
    }

    method visitBlock(node) -> Boolean {
        runRules(node)

        for(node.params) do { param ->
            runRules(aParameter.fromNode(param))
        }

        for(node.body) do { stmt ->
            stmt.accept(self)
        }

        return false
    }

    method visitMatchCase(node) -> Boolean {
        checkMatch(node)
    }

    method visitTryCatch(node) -> Boolean {
        checkMatch(node)
    }

    method visitMethodType(node) -> Boolean {
        runRules(node)

        for(node.signature) do { part ->
            for(part.params) do { param ->
                runRules(aParameter.fromNode(param))
            }
        }

        return false
    }

    method visitType(node) -> Boolean {
        checkMatch(node)
    }

    method visitMethod(node) -> Boolean {
        runRules(node)

        for(node.signature) do { part ->
            for(part.params) do { param ->
                runRules(aParameter.fromNode(param))
            }
        }

        for(node.body) do { stmt ->
            stmt.accept(self)
        }

        return false
    }

    method visitCall(node) -> Boolean {
        checkMatch(node)

        match(node.receiver) case { memb : Member ->
            memb.receiver.accept(self)
        } case { _ -> }

        for(node.parts) do { part ->
            for(part.args) do { arg ->
                arg.accept(self)
            }
        }

        return false
    }

    method visitObject(node) -> Boolean {
        checkMatch(node)
    }

    method visitArray(node) -> Boolean {
        checkMatch(node)
    }

    method visitMember(node) -> Boolean {
        checkMatch(node)
    }

    method visitGeneric(node) -> Boolean {
        checkMatch(node)
    }

    method visitIdentifier(node) -> Boolean {
        checkMatch(node)
    }

    method visitOctets(node) -> Boolean {
        checkMatch(node)
    }

    method visitString(node) -> Boolean {
        checkMatch(node)
    }

    method visitNum(node) -> Boolean {
        checkMatch(node)
    }

    method visitOp(node) -> Boolean {
        checkMatch(node)
    }

    method visitBind(node) -> Boolean {
        checkMatch(node)
    }

    method visitDefDec(node) -> Boolean {
        checkMatch(node)
    }

    method visitVarDec(node) -> Boolean {
        checkMatch(node)
    }

    method visitImport(node) -> Boolean {
        checkMatch(node)
    }

    method visitReturn(node) -> Boolean {
        checkMatch(node)
    }

    method visitInherits(node) -> Boolean {
        checkMatch(node)
    }

    method visitDialect(node) -> Boolean {
        checkMatch(node)
    }

}

def aTypeAnnotation is confidential = object {
    class fromNode(node) -> TypeAnnotation {
        def kind is public = "dtype"
        def value is public = node
        def line is public = node.line
        def linePos is public = node.linePos
        method == (o) { self.isMe(o) }
    }
}

def aParameter is confidential = object {
    class fromNode(node) -> Parameter {
        def kind is public = "parameter"
        def value is public = node.value
        def dtype is public = node.dtype
        def line is public = node.line
        def linePos is public = node.linePos
        method == (o) { self.isMe(o) }
    }
}

