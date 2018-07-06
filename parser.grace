#pragma ExtendedLineups
import "io" as io
import "ast" as ast
import "util" as util
import "errormessages" as errormessages

var lastLine := 0
var lastIndent := 0
var indentFreePass := false
var minIndentLevel := 0
var statementIndent := 0
var tokens := false
var moduleObject
var comments := emptyList   // so we can request `removeAt`

var auto_count := 0
def noBlocks = false
def blocksOK = true


var values := [ ]

//  The alternative definition below allows pushes and pops of `values`
//  to be traced.  It can be useful for debugging the parser.
//  def values = object {
//      def realValues = [ ]
//      var tracing is public := false
//      method push(v) {
//          if (tracing) then {
//              print "pushed {v.toGrace 0} (line {v.line})"
//          }
//          realValues.push(v)
//      }
//      method pop {
//          def res = realValues.pop
//          if (tracing) then {
//              print "popped {res.toGrace 0} (line {res.line})"
//          }
//          res
//      }
//      method size { realValues.size }
//      method filter(b) { realValues.filter(b) }
//      method isEmpty { realValues.isEmpty }
//      method last { realValues.last }
//      method do(b) { realValues.do(b) }
//  }

// sym is a module-level field containing the current token
var sym := object {
    def kind is public = "start"
    def line is public = 0
    def linePos is public = 0
    def indent is public = 0
    def value is public = ""
    def size is public = 0
    method ==(other) {
        if (other == false) then {
            false
        } else {
            (other.line == line) && (other.linePos == linePos)
        }
    }
}

var lastToken := sym
var previousCommentToken := lastToken
var statementToken := lastToken     // the token starting the current statement
var comment := false

method next {
    // Advance to the next token in the stream, assigning it to sym.
    // Put the position in the input into util module variables.

    if (tokens.size > 0) then {
        lastToken := sym
        lastLine := lastToken.line
        lastIndent := lastToken.indent
        sym := tokens.poll
        if (util.verbosity > 110) then { io.error.write "{sym}\n" }
        pushComments
        util.setPosition(sym.line, sym.linePos)
    } else {
        errormessages.syntaxError("unexpectedly found the end of the input. " 
            ++ "This is often caused by a missing '\}'")
            atPosition(sym.line, sym.linePos)
    }
}

method indentHasIncreased {
    // is lastToken on a line that is a continuation of the previous line?

    if (lastIndent == 0) then {
        return false        // this ensures that there will be a previous symbol
                            // on a prior line, and we won't hit start of input.
    }
    var s := sym.prev
    do { s := s.prev } while { s.line == lastLine }
    if ( s.kind == "lbrace" ) then { return false }
    if ( s.kind == "comment" ) then { return false }
    return s.indent < lastIndent
}

method saveParsePosition {
    def lexerState = tokens.savePosition
    return [lexerState, values.size]
}

method restoreParsePosition(saved) {
    tokens.restorePosition(saved.first)
    sym := tokens.first.prev
    lastToken := sym.prev
    def oldValueStackSize = saved.second
    if (oldValueStackSize > values.size) then {
        ProgrammingError.raise "can't restore parse position; the values stack has been popped"
    }
    while {oldValueStackSize ≠ values.size} do { values.pop }
}

method findNextToken(tokenMatcher) {
    // Search for the next token for which the given block returns true.
    // Used for generating suggestions.

    if (tokenMatcher.apply(sym)) then {
        return sym
    }
    var nextTok := false
    var n := sym
    while {(false != n) && { false == nextTok } && { n.indent >= lastToken.indent }} do {
        if (tokenMatcher.apply(n)) then {
            nextTok := n
        }
        n := n.next
    }
    nextTok
}

method findNextTokenIndentedAt(tok) {
    if (((sym.line > tok.line) && (sym.indent <= tok.indent)) || (sym.kind == "eof")) then {
        return sym
    }
    var nextTok := false
    var n := sym
    while {(false != n) && { false == nextTok }} do {
        if (((n.line > tok.line) && (n.indent <= tok.indent)) || (sym.kind == "eof")) then {
            nextTok := n
        }
        n := n.next
    }
    nextTok
}

method findNextValidToken(validFollowTokens) {
    // Tokens that cannot start an expression.
    def invalidTokens = set ["dot", "comma", "colon", "rparen",
            "rbrace", "rsquare", "arrow", "bind"];
    var validToken := sym
    while {validToken.kind != "eof"} do {
        // If the token is a valid follow token, then return that token.
        if (validFollowTokens.contains(validToken.kind)) then {
            return validToken
        }
        // If the token is not an invalid token for starting an expression, return that token.
        if (!invalidTokens.contains(validToken.kind)) then {
            return validToken
        }
        // The token is invalid, go to the next one.
        validToken := validToken.next
    }
    return validToken
}

method findClosingBrace(token, inserted) {
    // Finds the closing brace for token (that is the beginning of a control
    // structure) -- an opening brace. Returns an object with two fields: found
    // and tok. If a closing brace is found, found is set to true, and tok is set to
    // the closing brace. Otherwise found is set to false, and tok is set to the
    // token that the closing brace should appear after.

    var n := sym
    var numOpening := if (inserted) then {1} else {0}
    var numClosing := 0
    def result = object {
        var found is public
        var tok is public
    }
    // Skip all tokens on the same line first.
    while {(n.kind != "eof") && (n.line == token.line)} do {
        if (n.kind == "lbrace") then {
            numOpening := numOpening + 1
        } elseif { n.kind == "rbrace" } then {
            numClosing := numClosing + 1
        }
        n := n.next
    }
    // Skip all tokens that have greater indent than the target closing brace.
    while {(n.kind != "eof") && (n.indent > token.indent)} do {
        if (n.kind == "lbrace") then {
            numOpening := numOpening + 1
        } elseif { n.kind == "rbrace" } then {
            numClosing := numClosing + 1 
        }
        n := n.next
    }
    if (n.kind == "rbrace") then {
        result.found := true
        result.tok := n
    } elseif {(n.prev.kind == "rbrace") && (numOpening == numClosing)} then {
        // Check that the number of opening and closing braces matches.
        result.found := true
        result.tok := n.prev
    } else {
        result.found := false
        result.tok := n.prev
    }
    result
}


method accept(t) {
    // True if the current token has kind t, where
    // t is "num", "string", "keyword", etc.
    sym.kind == t
}

method acceptKeyword (kw) {
    if (sym.kind != "keyword") then { return false }
    return sym.value == kw
}

method acceptKeyword (kw1) or (kw2) {
    if (sym.kind != "keyword") then { return false }
    if (sym.value == kw1) then { return true }
    return sym.value == kw2
}

method acceptSeparator {
    def k = sym.kind
    if (k == "separator") then { return true }
    if (k == "semicolon") then { return true }
    return false
}

method skipSeparators {
    while { acceptSeparator } do { next }
}

method acceptSameLine (t) {
    // True if the current token is a t, and it is on the same logical
    // line (either because it's on the same physical line, or because
    // it's on an indented continuation line).

    (sym.kind == t) && 
        ((lastLine == sym.line) || (sym.indent > lastIndent))
}
method acceptWithoutSpaces (t) {
    // True if the current token is a t, and follows the previous token
    // without any intervening spaces or continuation lines.

    (sym.kind == t) && 
        (lastLine == sym.line) && (sym.linePos == (lastToken.linePos + lastToken.size))
}
method accept (t) onLineOf (other) {
    // True if the current token is a t, and it is on the same logical
    // line as other (either because it's on the same physical
    // line, or because it's on an indented continuation line).
    (sym.kind == t) && ((other.line == sym.line) ||
        (sym.indent > other.indent))
}
method accept (t) onLineOfLastOr (other) {
    // True if the current token is a t, and it is on the same logical
    // line as the last token, or the other token.
    if (sym.kind != t) then { return false }
    if (lastLine == sym.line) then { return true }
    if (sym.indent > lastIndent) then { return true }  // continuation last
    if (other.line == sym.line) then { return true }
    if (sym.indent > other.indent) then { return true }      // continuation of other
    return false
}
method acceptArgumentOnLineOf(tok) {
    // True if the current token can start an argument to a request
    if (accept "string" onLineOf(tok)) then { return true }
    if (accept "num" onLineOf(tok)) then { return true }
    if (accept "lbrace" onLineOf(tok)) then { return true }
    if (accept "lsquare" onLineOf(tok)) then { return true }
    if (accept "identifier" onLineOf(tok)) then { 
        return (sym.value == "true") || (sym.value == "false")
    }
    return false
}
method tokenOnSameLine {
    // returns true if there is a token on the current logical line
    (lastLine == sym.line) || (sym.indent > lastIndent)
}
method tokenOnLineOfLastOr (other) {
    // returns true if there is a token on the current logical line, or one
    // the same line as `other`
    if (lastLine == sym.line) then { return true }
    if (sym.indent > lastIndent) then { return true }   // continuation of last
    if (other.line == sym.line) then { return true }
    if (sym.indent > other.indent) then { return true } // continuation of other
    return false
}
method didConsume (aParsingBlock) {
    // returns true if executing aParsingBlock consumes at least one token.
    def sz = values.size
    aParsingBlock.apply
    values.size != sz
}
method didNotConsume (aParsingBlock) {
    // returns true if executing aParsingBlock fails to consume any tokens.
    def sz = values.size
    aParsingBlock.apply
    values.size == sz
}
method pushnum {
    // Push the current token onto the output stack as a number
    var o := ast.numNode.new(sym.value)
    values.push(o)
    next
}

method pushstring {
    // Push the current token onto the output stack as a string
    var o := ast.stringNode.new(sym.value)
    o.end := ast.line (sym.line) column (sym.endPos)
    values.push(o)
    next
}

// Push the current token onto the output stack as an identifier.
// false means that this identifier has not been assigned a dtype (yet).
method pushidentifier {
    util.setPosition(sym.line, sym.linePos)
    def o = if (sym.value == "_") then {
        ast.identifierNode.wildcard(false)
    } else {
        ast.identifierNode.new(sym.value, false)
    }
    values.push(o)
    next
}

method checkAnnotation(ann) {
    if (ann.kind == "call") then {
        for (ann.parts) do {p->
            for (p.args) do {a->
                if ((a.kind == "identifier") && {false != a.dtype}) then {
                    var tok := sym
                    // Look back from the current token to try and find the tokens that cause this error.
                    while {tok.value != ":"} do { tok := tok.prev }
                    def suggestion = errormessages.suggestion.new
                    suggestion.deleteTokenRange(tok, tok.next)leading(true)trailing(false)
                    errormessages.syntaxError("an argument to an annotation cannot have a type.")
                          atRange(tok.line, tok.linePos, tok.next.endPos)
                          withSuggestion(suggestion)
                }
            }
        }
    }
    ann
}
method doannotation {
    if (acceptKeyword "is" .not) then {
        return false
    }
    next
    def anns = [ ]
    if (didNotConsume {expression(noBlocks)}) then {
        errorMissingAnnotation
    }
    while {accept("comma")} do {
        anns.push(checkAnnotation(values.pop))
        next
        if (didNotConsume {expression(noBlocks)}) then {
            errorMissingAnnotation
        }
    }
    anns.push(checkAnnotation(values.pop))
    anns
}

method errorMissingAnnotation {
    def suggestions = [ ]
    var suggestion := errormessages.suggestion.new
    def nextTok = findNextValidToken( ["bind"] )
    if (nextTok == sym) then {
        suggestion.insert(" «annotation»")afterToken(lastToken)
    } else {
        suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «annotation»")
    }
    suggestions.push(suggestion)
    suggestion := errormessages.suggestion.new
    suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
    suggestions.push(suggestion)
    errormessages.syntaxError("one or more annotations separated by commas must follow 'is'.")
        atRange(lastToken.line, lastToken.linePos, lastToken.endPos)
        withSuggestions(suggestions)
}

method dotypeterm {
    if (accept "identifier") then {
        pushidentifier
        generic
        dotrest(noBlocks)
    } else {
        if (acceptKeyword "type" or "interface") then {
            dotypeLiteral
        }
    }
}

method typeexpression {
    var sz := values.size
    if (accept "lparen") then {
        def prevStatementToken = statementToken
        statementToken := sym
        next
        if (didNotConsume {typeexpression}) then {
            def suggestion = errormessages.suggestion.new
            def nextTok = findNextValidToken( ["rparen"] )
            if (nextTok == sym) then {
                suggestion.insert("«type expression»")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextTok.prev) leading (true)
                    trailing(false) with "«type expression»"
            }
            errormessages.syntaxError "parentheses must contain a valid type expression."
                atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
        if (sym.kind != "rparen") then {
            checkBadOperators
            def suggestion = errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken)
            errormessages.syntaxError "a type expression beginning with a '(' must end with a ')'."
                atRange(lastToken.line, lastToken.linePos, lastToken.endPos)
                withSuggestion(suggestion)
        }
        statementToken := prevStatementToken
        next
    } else {
        dotypeterm
    }
    if (values.size > sz) then {
        dotrest(noBlocks)
        typeexpressionrest
    }
    // TODO: check that the expression doesn't contain requests or var references.
    // This has to happen in the identifier resolution phase.
}

method newIf(cond, thenList, elseList) {
    def thenBlock = ast.blockNode.new(emptySequence, thenList)
    def elseBlock = ast.blockNode.new(emptySequence, elseList)
    ast.ifNode.new(cond, thenBlock, elseBlock)
}

method reportSyntaxError(message) before (expectedTokens) {
    def suggestions = [ ]
    var suggestion := errormessages.suggestion.new
    def nextTok = findNextValidToken (expectedTokens)
    if (nextTok == sym) then {
        suggestion.insert(" «expression»")afterToken(lastToken)
    } else {
        suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «expression»")
    }
    suggestions.push(suggestion)
    suggestion := errormessages.suggestion.new
    suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
    suggestions.push(suggestion)
    errormessages.syntaxError(message)
        atPosition(sym.line, sym.linePos)
        withSuggestions(suggestions)
}

method reportMissingArrow {
    def suggestion = errormessages.suggestion.new
    if ((sym.kind == "bind") || (sym.value == "=")) then {
        suggestion.replaceToken(sym)with("->")
    } else {
        suggestion.insert(" ->")afterToken(lastToken)
    }
    errormessages.syntaxError("in a block with parameters, the parameters must be followed by '->'")
        atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
}

method reportBadRhs {
    // a bind symbol := was not followed by a valid expression.

    def suggestions = [ ]
    var suggestion := errormessages.suggestion.new
    def nextTok = findNextValidToken( ["rbrace"] )
    if (nextTok == sym) then {
        suggestion.insert(" «expression»")afterToken(lastToken)
    } else {
        suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «expression»")
    }
    suggestions.push(suggestion)
    suggestion := errormessages.suggestion.new
    suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
    suggestions.push(suggestion)
    errormessages.syntaxError("a valid expression must follow ':='.")
        atPosition(sym.line, sym.linePos) withSuggestions(suggestions)
}

method block {
    // Parses a block.  Since a block is (a) treated as a statement, and
    // (b) may have statements inside, we save and restore the setting of the
    // global variables relevant to the statement context.

    if (accept "lbrace") then {
        def btok = sym
        next
        skipSeparators
        def oldMinIndent = minIndentLevel
        def minInd = statementIndent + 2
        def oldStatementToken = statementToken
        def oldStatementIndent = statementIndent
        statementToken := sym
        var isMatchingBlock := false

        // a block may start with or without parameters.  We assume that
        // parameters are present, parse the first expression, and then check.
        // If it wasn't a parameter, we back-up the parse position.
        def savedPosition = saveParsePosition
        def params = blockParameters
        if (params.isEmpty) then {
            restoreParsePosition(savedPosition)
        }

        def blockNode = blockBody (params) beginningWith (btok)
        values.push(blockNode)
        minIndentLevel := oldMinIndent
        statementIndent := oldStatementIndent
        statementToken := oldStatementToken
    }
}

method blockParameters {
    // parse all the parameters of this block, and return them as a
    // collection of identifier nodes.
    def params = [ ]
    while {blockParameter(params)} do {
        if (accept "arrow") then {
            next
            return params
        }
        if (accept "comma") then {
            next
        } else {
            reportMissingArrow
        }
    }
    skipSeparators
    return params
}

method blockParameter(params) -> Boolean {
    // parse one parameter, if possible, push it onto params, and
    // return true. If the next expression is not a parameter, return false.

    var paramIsPattern := sym.kind == "lparen"
    // Parsing the expression ‹(a)› will return an identifierNode‹a› .
    // Checking for a paren lets us distinguish parameter from pattern.
    if (didConsume {expression(blocksOK)}) then {
        if (accept "comma" || accept "arrow" || accept "colon") then {
            // we have found a parameter
            var thisParam := values.pop
            if (paramIsPattern || thisParam.isIdentifier.not) then {
                paramIsPattern := true
                thisParam := ast.identifierNode.wildcard(thisParam)
                    // put the pattern in the type field
            }
            thisParam.isBindingOccurrence := true
            if (paramIsPattern && accept "colon") then {
                reportSyntaxError("a block parameter that's an expression is assumed to mean " ++
                      "_:‹expression›, and so cannot be followed by a colon")
                      before ["arrow", "comma"]
            }
            if (accept "colon") then {
                // We allow an expression for v: <PatternExpression>
                next
                if (didConsume {expression(blocksOK)} .not) then {
                    reportSyntaxError "a block parameter must have a pattern or type expression after the ':'." before ["arrow", "rbrace"]
                }
                thisParam.dtype := values.pop
            }
            params.push(thisParam)
            return true
        } else {
            // we just parsed the first expression in the block
            return false
        }
    } else {
        return false    // we didn't parse anything
    }
}

method blockBody(params) beginningWith (btok) {
    // returns a block AST node.  params is the list of parameters,
    // which may be empty, and btok the lbrace that started the block.
    // The module variable sym is the first token in the body, and lastToken
    // is the preceeding lbrace that started the block, or the arrow that
    // terminated the parameter list (if there was one),
    // or the comment that appears after the lbrace, if there was one.

    def originalValues = values
    values := []
    if (sym.line == lastToken.line) then {
        indentFreePass := true
    }
    while {accept "rbrace".not} do {
        // Take the body of the block
        if (didNotConsume {statement}) then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert "}" afterToken (lastToken)
            errormessages.syntaxError "a block must end with a '}'."
                atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
    }
    def etok = sym  // the closing rbrace
    next
    def body = values
    if ((etok.line ≠ btok.line) && (body.isEmpty.not)) then {
        if (body.last.linePos == (btok.indent + 1)) then {
            errormessages.syntaxError "the body of a block must be indented."
                atRange(body.first.range)
        }
    }
    values := originalValues
    return ast.blockNode.new(params, body).setPositionFrom(btok)
}


// Accept an "if" statement. This is a special syntactic case, rather
// than just a call with a multi-part method name - it might be possible
// to change that and compensate later on.
method doif {
    if (accept("identifier") && (sym.value == "if")) then {
        def btok = sym
        def minStartColumn = sym.indent + 3
            // if the `if` has indent 0, then `then`, `else` etc. must
            // start in column 3 or more.
        next
        def opener = if ((sym.kind == "lparen") || {sym.kind == "lbrace"})
                        then { sym.value } else { "-missing-" }
        def closer = if (opener == "(") then { ")" }
                        else { if (opener == "\{") then { "\}" } else { "-nothing-" } }
        if (opener == "-missing-") then {
            def suggestion = errormessages.suggestion.new
            // Look ahead for a rparen or then.
            def nextTok = findNextToken { t ->
                (t.line == btok.line) && ((t.kind == "rparen") ||
                    (t.kind == "rbrace") || (t.kind == "lbrace") ||
                    ((t.kind == "identifier") && (t.value == "then")))
            }
            if (false == nextTok) then {
                suggestion.insert(" («condition») then \{")afterToken(btok)
            } elseif { nextTok.kind == "rparen" } then {
                if (nextTok == sym) then {
                    suggestion.insert("(«condition»")beforeToken(sym)
                } else {
                    suggestion.insert("(")beforeToken(sym)
                }
            } elseif { nextTok.kind == "lbrace" } then {
                if (nextTok == sym) then {
                    suggestion.insert(" («condition») then")afterToken(btok)
                } else {
                    suggestion.insert("(")beforeToken(sym)
                    suggestion.insert(") then")afterToken(nextTok.prev)andTrailingSpace(true)
                }
            } elseif { nextTok.kind == "identifier" } then {
                if (nextTok == sym) then {
                    suggestion.insert("(«condition») ")beforeToken(sym)
                } else {
                    suggestion.insert("(")beforeToken(sym)
                    suggestion.insert(")")afterToken(nextTok.prev)andTrailingSpace(true)
                }
            }
            errormessages.syntaxError("an if statement must have a condition " ++
                "in parentheses or braces after the 'if'.")
                atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
        next
        if (didNotConsume {expression(blocksOK)}) then {
            def suggestion = errormessages.suggestion.new
            // Look ahead for a rparen.
            var nextTok := findNextToken({ t -> (t.line == lastToken.line) && (t.kind == "rparen") })
            if (false == nextTok) then {
                nextTok := findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression») then \{")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)
                          leading(true)trailing(false)with("«expression») then \{")
                }
                errormessages.syntaxError("an if statement must have a " ++
                      "condition in parentheses or braces after the 'if'.")
                      atPosition(sym.line, sym.linePos)
                      withSuggestion(suggestion)
            } else {
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                    errormessages.syntaxError("an if statement must have a " ++
                        "condition in parentheses or braces after the 'if'.")
                        atPosition(sym.line, sym.linePos)
                        withSuggestion(suggestion)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)
                        leading(false)trailing(true)with("«expression»")
                    errormessages.syntaxError("an if statement must have a " ++
                        "condition in parentheses or braces after the 'if'.")
                        atRange(sym.line, sym.linePos, nextTok.linePos - 1)
                        withSuggestion(suggestion)
                }
            }
        }
        if (sym.value != closer) then {
            checkBadOperators
            def suggestion = errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken)
            errormessages.syntaxError("an expression beginning with a "++
                  "'{opener}' must end with a '{closer}'.")
                  atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                  withSuggestion(suggestion)
        }
        next
        var cond := values.pop
        var body := []

        var elseblock := []
        var curelse := elseblock
            // These two variables are for else/elseif handling. An 'elseif' is
            // turned into nested 'if' statements for the AST; `curelse` points
            // to the most deeply-nested of those (where any eventual "else"
            // blocks will go). `elseblock` contains the statements of the
            // top-level 'else' block --- if there are any 'elseif's, that top-
            // level 'else' will comprise just one statement: another if.
        var v
        def localMin = minIndentLevel
        def localStatementIndent = statementIndent
        var minInd := statementIndent + 2
        if (accept("identifier") && (sym.value == "then")) then {
            if (sym.linePos < minStartColumn) then {
                errormessages.syntaxError("the 'then' part of an " ++
                    "'if(_)then(_)…' must be indented more than the 'if'")
                    atRange(sym.line, sym.linePos, sym.linePos + 3)
            }
            next
            if (sym.kind != "lbrace") then {
                def suggestion = errormessages.suggestion.new
                def closingBrace = findClosingBrace(btok, true)
                if (closingBrace.found.not) then {
                    if (closingBrace.tok == lastToken) then {
                        suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{}")
                    } else {
                        suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                        suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{")
                    }
                } else {
                    suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{")
                }
                errormessages.syntaxError("an if statement must have a '\{' after the 'then'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
            if (sym.line == lastToken.line) then {
                minIndentLevel := sym.linePos - 1
            } else {
                minIndentLevel := minInd
            }
            while {didConsume {statement}} do {
                skipSeparators
                if (values.isEmpty) then {
                    ProgrammingError.raise "values is empty.\n  commentStack = {comments}\nsym = {sym}"
                }
                body.push(values.pop)
            }
            if ((accept "rbrace").not) then {
                def suggestion = errormessages.suggestion.new
                def closingBrace = findClosingBrace(btok, false)
                if (closingBrace.found.not) then {
                    if (closingBrace.tok == lastToken) then {
                        suggestion.insert("}")afterToken(lastToken)
                    } else {
                        suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                    }
                }
                suggestion.deleteToken(sym)
                errormessages.syntaxError("an if statement must end with a '}'.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }

            next
            var econd
            var eif
            var newelse
            var ebody
            while {accept("identifier") && (sym.value == "elseif")} do {
                // Currently, the parser just accepts arbitrarily many
                // "elseifs", turning them into ifs inside the else.
                // TODO: allow blocks after elseif to contain a sequence of expressions.
                if (sym.linePos < minStartColumn) then {
                    errormessages.syntaxError("the 'elseif' part of an " ++
                        "'if(_)then(_)…elseif(_)' must be indented more than the 'if'")
                        atRange(sym.line, sym.linePos, sym.linePos + 5)
                }
                statementToken := sym
                next
                if (sym.kind != "lbrace") then {
                    def suggestion = errormessages.suggestion.new
                    // Look ahead for a rbrace or then.
                    def nextTok = findNextToken { t ->
                        (t.line == statementToken.line)
                            && ((t.kind == "rbrace") || (t.kind == "lbrace")
                            || ((t.kind == "identifier") && (t.value == "then"))) }
                    if (false == nextTok) then {
                        suggestion.insert(" \{ «expression» \} then \{")afterToken(statementToken)
                    } elseif { nextTok.kind == "rbrace" } then {
                        if (nextTok == sym) then {
                            suggestion.insert("\{ «expression» \}")beforeToken(sym)
                        } else {
                            suggestion.insert("\{ ")beforeToken(sym)
                        }
                    } elseif { nextTok.kind == "lbrace" } then {
                        if (nextTok == sym) then {
                            suggestion.insert(" \{ «expression» \} then")afterToken(statementToken)
                        } else {
                            suggestion.insert("\{ ")beforeToken(sym)
                            suggestion.insert(" \} then")afterToken(nextTok.prev)andTrailingSpace(true)
                        }
                    } elseif { nextTok.kind == "identifier" } then {
                        if (nextTok == sym) then {
                            suggestion.insert("\{ «expression» \} ")beforeToken(sym)
                        } else {
                            suggestion.insert("\{ ")beforeToken(sym)
                            suggestion.insert(" \}")afterToken(nextTok.prev)andTrailingSpace(true)
                        }
                    }
                    errormessages.syntaxError("an elseif statement must have a " ++
                          "condition in braces after the 'elseif'.")
                          atPosition(sym.line, sym.linePos)
                          withSuggestion(suggestion)
                }
                next
                if (didNotConsume {expression(blocksOK)}) then {
                    def suggestion = errormessages.suggestion.new
                    // Look ahead for a rbrace or then.
                    var nextTok := findNextToken { t ->
                        (t.line == lastToken.line) && (t.kind == "rbrace")}
                    if (false == nextTok) then {
                        nextTok := findNextValidToken( ["rbrace"] )
                        if (nextTok == sym) then {
                            suggestion.insert("«expression» \} then \{")afterToken(lastToken)
                        } else {
                            suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression» \} then \{")
                        }
                        errormessages.syntaxError("an elseif clause must have an expression in braces after the 'elseif'.")atPosition(
                            sym.line, sym.linePos)withSuggestion(suggestion)
                    } else {
                        if (nextTok == sym) then {
                            suggestion.insert("«expression»")afterToken(lastToken)
                            errormessages.syntaxError("an elseif clause must have an expression in braces after the 'elseif'.")atPosition(
                                sym.line, sym.linePos)withSuggestion(suggestion)
                        } else {
                            //checkInvalidExpression
                            suggestion.replaceTokenRange(sym, nextTok.prev)leading(false)trailing(true)with("«expression»")
                            errormessages.syntaxError("(4) an elseif statement must have an expression in braces after the 'elseif'.")atRange(
                                sym.line, sym.linePos, nextTok.linePos - 1)withSuggestion(suggestion)
                        }
                    }
                }
                if (sym.value != "\}") then {
                    checkBadOperators
                    def suggestion = errormessages.suggestion.new
                    suggestion.insert "}" afterToken (lastToken)
                    errormessages.syntaxError("a condition beginning with a " ++
                        "'\{' must end with a '\}'.")
                        atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                        withSuggestion(suggestion)
                }
                next
                econd := values.pop
                if (accept "identifier" && (sym.value == "then")) then {
                    if (sym.linePos < minStartColumn) then {
                        errormessages.syntaxError("the 'then' part of an " ++
                            "'if(_)…elseif(_)then(_)' must be indented more than the 'if'")
                            atRange(sym.line, sym.linePos, sym.linePos + 3)
                    }
                    next
                    ebody := []
                } else {
                    def suggestion = errormessages.suggestion.new
                    if (sym.kind == "lbrace") then {
                        def closingBrace = findClosingBrace(statementToken, false)
                        if (closingBrace.found.not) then {
                            if (closingBrace.tok == sym) then {
                                suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{}")
                            } else {
                                suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{")
                                suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            }
                        } else {
                            suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{")
                        }
                    } else {
                        def closingBrace = findClosingBrace(statementToken, true)
                        if (closingBrace.found.not) then {
                            if (closingBrace.tok == lastToken) then {
                                suggestion.insert(" then \{}")afterToken(lastToken)
                            } else {
                                suggestion.insert(" then \{")afterToken(lastToken)
                                suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            }
                        } else {
                            suggestion.insert(" then \{")afterToken(lastToken)
                        }
                    }
                    errormessages.syntaxError("an elseif clause must have 'then' after the expression in braces.")
                          atPosition(sym.line, sym.linePos)withSuggestion(suggestion)
                }
                if (sym.kind != "lbrace") then {
                    def suggestion = errormessages.suggestion.new
                    def closingBrace = findClosingBrace(btok, true)
                    if (closingBrace.found.not) then {
                        if (closingBrace.tok == lastToken) then {
                            suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{}")
                        } else {
                            suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{")
                        }
                    } else {
                        suggestion.replaceToken(lastToken)leading(false)trailing(true)with("then \{")
                    }
                    errormessages.syntaxError("an elseif clause must have a '\{' after the 'then'.")atPosition(
                        lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
                }
                next
                if (sym.line == lastToken.line) then {
                    minIndentLevel := sym.linePos - 1
                } else {
                    minIndentLevel := minInd
                }
                while {(accept("rbrace")).not} do {
                    if (didNotConsume {statement}) then {
                        def suggestion = errormessages.suggestion.new
                        def closingBrace = findClosingBrace(btok, false)
                        if (closingBrace.found.not) then {
                            if (closingBrace.tok == lastToken) then {
                                suggestion.insert("}")afterToken(lastToken)
                            } else {
                                suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            }
                        }
                        suggestion.deleteToken(sym)
                        errormessages.syntaxError("an 'elseif' clause must end with a '}'.")atPosition(
                            sym.line, sym.linePos)withSuggestion(suggestion)
                    }
                    v := values.pop
                    ebody.push(v)
                }
                next
                newelse := []
                eif := newIf(econd, ebody, newelse)
                // Construct the inner "if" AST node, and then push it
                // inside the current "else" block.
                curelse.push(eif)
                // Update curelse to point to the new, empty, nested
                // else block.
                curelse := newelse
            }
            if (accept("identifier") && (sym.value == "else")) then {
                if (sym.linePos < minStartColumn) then {
                    errormessages.syntaxError("the 'else' part of an " ++
                        "'if(_)then(_)…else(_)' must be indented more than the 'if'")
                        atRange(sym.line, sym.linePos, sym.linePos + 3)
                }
                next
                if (sym.kind != "lbrace") then {
                    def suggestion = errormessages.suggestion.new
                    def closingBrace = findClosingBrace(btok, true)
                    if (closingBrace.found.not) then {
                        if (closingBrace.tok == lastToken) then {
                            suggestion.replaceToken(lastToken)leading(false)trailing(true)with("else \{}")
                        } else {
                            suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            suggestion.replaceToken(lastToken)leading(false)trailing(true)with("else \{")
                        }
                    } else {
                        suggestion.replaceToken(lastToken)leading(false)trailing(true)with("else \{")
                    }
                    errormessages.syntaxError("an else clause must start with a '\{' after the 'else'.")
                          atPosition(lastToken.line, lastToken.linePos + lastToken.size - 1)
                          withSuggestion(suggestion)
                }
                next
                // Just take all the statements and put them into
                // curelse.
                if (sym.line == lastToken.line) then {
                    minIndentLevel := sym.linePos - 1
                } else {
                    minIndentLevel := minInd
                }
                while {(accept("rbrace")).not} do {
                    if (didNotConsume {statement}) then {
                        def suggestion = errormessages.suggestion.new
                        def closingBrace = findClosingBrace(btok, false)
                        if (closingBrace.found.not) then {
                            if (sym.kind == "eof") then {
                                errormessages.syntaxError("end of program " ++
                                    "found while searching for the '}' to close " ++
                                      "an 'else' statement.")
                                        atPosition(sym.line, sym.linePos)
                            }
                            if (closingBrace.tok == lastToken) then {
                                suggestion.insert("}")afterToken(lastToken)
                            } else {
                                suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                            }
                        }
                        suggestion.deleteToken(sym)
                        errormessages.syntaxError("an else statement must end with a '}'.")atPosition(
                            sym.line, sym.linePos)withSuggestion(suggestion)
                    }
                    v := values.pop
                    curelse.push(v)
                }
                next
            }
            util.setPosition(btok.line, btok.linePos)
            var o := newIf(cond, body, elseblock)
            values.push(o)
        } else {
            // Raise an error here, or it will spin nastily forever.
            def suggestion = errormessages.suggestion.new
            if (sym.kind == "lbrace") then {
                def closingBrace = findClosingBrace(btok, false)
                if (closingBrace.found.not) then {
                    if (closingBrace.tok == sym) then {
                        suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{}")
                    } else {
                        suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{")
                        suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                    }
                } else {
                    suggestion.replaceToken(sym)leading(true)trailing(false)with(" then \{")
                }
            } else {
                def closingBrace = findClosingBrace(btok, true)
                if (closingBrace.found.not) then {
                    if (closingBrace.tok == lastToken) then {
                        suggestion.insert(" then \{}")afterToken(lastToken)
                    } else {
                        suggestion.insert(" then \{")afterToken(lastToken)
                        suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                    }
                } else {
                    suggestion.insert(" then \{")afterToken(lastToken)
                }
            }
            errormessages.syntaxError("an if statement must have 'then' after " ++
                  "the condition in parentheses.")
                  atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
        minIndentLevel := localMin
        statementIndent := localStatementIndent
    }
}

// Accept an identifier. Handle "if" specially by
// passing it to the method above.
method identifier {
    if (accept "identifier") then {
        if (sym.value == "if") then {
            doif
        } else {
            pushidentifier
        }
    }
}

method prefixop {
    def startIndent = minIndentLevel
    if (accept "op") then {
        var op := sym.value
        next
        if (accept "lparen") then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestion = errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
                }
                errormessages.syntaxError("parentheses must contain a valid expression.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
            if (sym.kind != "rparen") then {
                checkBadOperators
                def suggestion = errormessages.suggestion.new
                suggestion.insert(")")afterToken(lastToken)
                errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
        } else {
            if (didNotConsume {term}) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
                }
                suggestions.push(suggestion)
                if (lastToken.prev.kind == "bind") then {
                    suggestion := errormessages.suggestion.new
                    suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
                    suggestion.deleteToken(lastToken.prev)leading(true)trailing(false)
                    suggestions.push(suggestion)
                }
                errormessages.syntaxError("a prefix operator must be followed by an expression.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestions(suggestions)
            }
        }
        dotrest(blocksOK)
        callrest(blocksOK)
        def rcvr = values.pop
        def call = ast.callNode.new(rcvr,
            [ ast.requestPart.request("prefix" ++ op) withArgs( [] ) ] )
        call.end := ast.line (lastLine) column (lastToken.endPos)
        values.push(call)
        minIndentLevel := startIndent
    }
}

method generic {
    if (accept "lgeneric") then {
        def id = values.pop
        def gens = [ ]
        def startToken = sym
        next
        while {accept("identifier")} do {
            identifier
            while {accept("dot")} do {
                next
                def memberIn = values.pop
                if (sym.kind != "identifier") then {
                    def suggestions = [ ]
                    var suggestion := errormessages.suggestion.new
                    suggestion.insert("«type name»")afterToken(lastToken)
                    suggestions.push(suggestion)
                    suggestion := errormessages.suggestion.new
                    suggestion.deleteToken(lastToken)
                    suggestions.push(suggestion)
                    errormessages.syntaxError("a type name must follow the '.'.")atPosition(
                        lastToken.line, lastToken.linePos + 1)withSuggestions(suggestions)
                }
                identifier
                def memberName = values.pop
                def memberNd = ast.memberNode.new(memberName.value, memberIn)
                memberNd.line := memberName.line
                memberNd.linePos := memberName.linePos
                values.push(memberNd)
            }
            generic
            gens.push(values.pop)
            if (accept "comma") then {
                next
            } else {
                if (sym.kind != "rgeneric") then {
                    def suggestion = errormessages.suggestion.new
                    suggestion.insert(">")afterToken(lastToken)
                    def suggestion2 = errormessages.suggestion.new
                    suggestion2.insert(" ")beforeToken(startToken)
                    def suggestions = [suggestion, suggestion2]
                    errormessages.syntaxError("a type containing a '⟦' must end with a '⟧'.")
                          atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                          withSuggestions(suggestions)
                }
            }
        }
        if (sym.kind != "rgeneric") then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert(">")afterToken(lastToken)
            def suggestion2 = errormessages.suggestion.new
            suggestion2.insert(" ")beforeToken(startToken)
            def suggestions = [suggestion, suggestion2]
            errormessages.syntaxError("a type containing a '⟦' must end with a '⟧'.")
                  atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                  withSuggestions(suggestions)
        }
        next
        values.push(ast.genericNode.new(id, gens))
    }
}
method trycatch {
    if (!(accept "identifier" && {sym.value == "try"})) then {
        return
    }
    def localmin = minIndentLevel
    def tryTok = sym
    next
    if (accept "lbrace") then {
        block
    } else {
        if (sym.kind != "lparen") then {
            def suggestion = errormessages.suggestion.new
            // Look ahead for a rbrace, rparen, or catch.
            def nextTok = findNextToken({ t -> (t.kind == "rbrace")
                || ((t.kind == "rparen") && (t.line == tryTok.line))
                || ((t.kind == "identifier") && (t.value == "catch")) })
            if (false == nextTok) then {
                suggestion.insert(" \{}")afterToken(tryTok)
            } elseif { nextTok.kind == "rbrace" } then {
                suggestion.insert(" \{")afterToken(tryTok)
            } elseif { nextTok.kind == "rparen" } then {
                if (nextTok == sym) then {
                    suggestion.insert("(«expression»")afterToken(lastToken)andTrailingSpace(true)
                } else {
                    suggestion.insert("(")afterToken(lastToken)andTrailingSpace(true)
                }
            } elseif { nextTok.kind == "identifier" } then {
                suggestion.insert(" \{")afterToken(tryTok)
                suggestion.insert("\} ")beforeToken(nextTok)
            }
            errormessages.syntaxError("a try(_)catch(_) statement must have " ++
                "a block or an expression in parentheses after the 'try'.")
                atPosition(tryTok.line, tryTok.endPos + 1)
                withSuggestion(suggestion)
        }
        next
        if (didNotConsume {expression(blocksOK)}) then {
            def suggestion = errormessages.suggestion.new
            def nextTok = findNextValidToken( ["rparen"] )
            if (nextTok == sym) then {
                suggestion.insert("«expression»")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
            }
            errormessages.syntaxError("a 'try(_)catch(_)…' statement must have " ++
                "a block or an expression in parentheses after the 'try'.")
                atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
        if (sym.kind != "rparen") then {
            checkBadOperators
            def suggestion = errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken)
            errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")
                atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                withSuggestion(suggestion)
        }
        next
    }
    def mainblock = values.pop
    def cases = []
    var finally := false
    while {accept("identifier") && (sym.value == "catch")} do {
        next
        if (accept "lbrace") then {
            block
        } elseif { accept "lparen" } then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestion = errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
                }
                errormessages.syntaxError("a try-catch statement must have either a matching block or an expression in parentheses after the 'catch'.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
            if (sym.kind != "rparen") then {
                checkBadOperators
                def suggestion = errormessages.suggestion.new
                suggestion.insert(")")afterToken(lastToken)
                errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
        } else {
            def suggestions = [ ]
            def nextTok = findNextTokenIndentedAt(lastToken)
            var suggestion := errormessages.suggestion.new
            if (false == nextTok) then {
                suggestion.insert(" }")afterToken(tokens.last)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            } elseif { nextTok == sym } then {
                suggestion.insert(" («expression»)")afterToken(lastToken)
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.insert(" \{ «match expression» }")afterToken(lastToken)
                suggestions.push(suggestion)
            } else {
                suggestion.insert(" }")afterToken(nextTok.prev)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            }
            errormessages.syntaxError("a 'try(_)catch(_)…' statement must have " ++
                  "either a matching block or an expression in parentheses after the 'catch'.")
                    atPosition(sym.line, sym.linePos) withSuggestions (suggestions)
        }
        cases.push(values.pop)
    }
    if (accept("identifier")onLineOf(tryTok) && (sym.value == "case")) then {
        def suggestion = errormessages.suggestion.new
        suggestion.replaceToken(sym)with("catch")
        errormessages.syntaxError("a 'try(_)catch(_)…' statement starts with a "
                ++ "'try', followed by zero or more 'catch' blocks; there "
                ++ "are no 'case' blocks.")
            atRange(sym.line, sym.linePos, sym.linePos + 3)
            withSuggestion(suggestion)
    }
    if (accept("identifier") && (sym.value == "finally")) then {
        next
        if (accept "lbrace") then {
            block
        } elseif { accept "lparen" } then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestion = errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
                }
                errormessages.syntaxError("a 'try(_)catch(_)…finally(_)' statement " ++
                    "must have either a block, or an expression in parentheses, " ++
                    "after the 'finally'.")
                    atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
            }
            if (sym.kind != "rparen") then {
                checkBadOperators
                def suggestion = errormessages.suggestion.new
                suggestion.insert(")")afterToken(lastToken)
                errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
        } else {
            def suggestions = [ ]
            def nextTok = findNextTokenIndentedAt(lastToken)
            var suggestion := errormessages.suggestion.new
            if (false == nextTok) then {
                suggestion.insert(" }")afterToken(tokens.first)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            } elseif { nextTok == sym } then {
                suggestion.insert(" («expression»)")afterToken(lastToken)
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.insert(" \{ «expression» }")afterToken(lastToken)
                suggestions.push(suggestion)
            } else {
                suggestion.insert(" }")afterToken(nextTok.prev)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            }
            errormessages.syntaxError("a try(_)catch(_)…finally(_) statement must have either a block or an expression in parentheses after the 'finally'.")atPosition(
                sym.line, sym.linePos)withSuggestions(suggestions)
        }
        finally := values.pop
    }
    util.setPosition(tryTok.line, tryTok.linePos)
    values.push(ast.tryCatchNode.new(mainblock, cases, finally))
    minIndentLevel := localmin
}
method matchcase {
    if (!(accept("identifier") && (sym.value == "match"))) then {
        return 0
    }
    def localmin = minIndentLevel
    def matchTok = sym
    next
    if (sym.kind != "lparen") then {
        def suggestion = errormessages.suggestion.new
        // Look ahead for a rparen or case.
        def nextTok = findNextToken({ t -> ((t.kind == "rparen") && (t.line == matchTok.line))
            || ((t.kind == "identifier") && (t.value == "case")) })
        if (false == nextTok) then {
            suggestion.insert("(«expression»)")afterToken(matchTok)
        } elseif { nextTok.kind == "rparen" } then {
            if (nextTok == sym) then {
                suggestion.insert("(«expression»")beforeToken(sym)
            } else {
                suggestion.insert("(")beforeToken(sym)
            }
        } elseif { nextTok.kind == "identifier" } then {
            suggestion.insert("(")beforeToken(sym)
            suggestion.insert(")")afterToken(nextTok.prev)andTrailingSpace(true)
        }
        errormessages.syntaxError("a match statement must have an expression in parentheses after the 'match'.")atPosition(
            matchTok.line, matchTok.linePos + matchTok.size)withSuggestion(suggestion)
    }
    next
    if (didNotConsume {expression(blocksOK)}) then {
        def suggestion = errormessages.suggestion.new
        def nextTok = findNextValidToken( ["rparen"] )
        if (nextTok == sym) then {
            suggestion.insert("«expression»")afterToken(lastToken)
        } else {
            suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
        }
        errormessages.syntaxError("a match statement must have an expression in parentheses after the 'match'.")atPosition(
            sym.line, sym.linePos)withSuggestion(suggestion)
    }
    def matchee = values.pop
    if (sym.kind != "rparen") then {
        checkBadOperators
        def suggestion = errormessages.suggestion.new
        suggestion.insert(")")afterToken(lastToken)
        errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
            lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
    }
    next
    def cases = []
    while {accept("identifier") && (sym.value == "case")} do {
        next
        if (accept "lbrace") then {
            block
        } elseif { accept "lparen" } then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestion = errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«expression»")
                }
                errormessages.syntaxError("a match statement must have either a matching block or an expression in parentheses after the 'case'.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
            if (sym.kind != "rparen") then {
                checkBadOperators
                def suggestion = errormessages.suggestion.new
                suggestion.insert(")")afterToken(lastToken)
                errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
        } else {
            def suggestions = [ ]
            def nextTok = findNextTokenIndentedAt(lastToken)
            var suggestion := errormessages.suggestion.new
            if (false == nextTok) then {
                suggestion.insert(" }")afterToken(tokens.last)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            } elseif { nextTok == sym } then {
                suggestion.insert(" («expression»)")afterToken(lastToken)
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.insert(" \{ «match expression» }")afterToken(lastToken)
                suggestions.push(suggestion)
            } else {
                suggestion.insert(" }")afterToken(nextTok.prev)
                suggestion.insert(" \{")afterToken(lastToken)
                suggestions.push(suggestion)
            }
            errormessages.syntaxError("a match statement must have either a matching block or an expression in parentheses after the 'case'.")atPosition(
                sym.line, sym.linePos)withSuggestions(suggestions)
        }
        cases.push(values.pop)
    }
    util.setPosition(matchTok.line, matchTok.linePos)
    values.push(ast.matchCaseNode.new(matchee, cases))
    minIndentLevel := localmin
}
// Accept a term. Terms consist only of single syntactic units and
// do not contain any operators or parentheses, unlike expression.
method term {
    util.setPosition(sym.line, sym.linePos)
    if (accept "num") then {
        pushnum
    } elseif { accept "string" } then {
        pushstring
    } elseif { accept "identifier" && (sym.value == "match") } then {
        matchcase
    } elseif { accept("identifier") && (sym.value == "try") } then {
        trycatch
    } elseif { accept "identifier" } then {
        identifier
    } elseif { acceptKeyword "object" } then {
        doobject
    } elseif { acceptKeyword "type" or "interface" } then {
        dotypeLiteral
    } elseif { accept "lbrace" } then {
        block
    } elseif { accept "lsquare" } then {
        doarray
    } elseif { accept "op" } then {
        // Prefix operator
        prefixop
    }
}

// Accept an expression. Expressions may consist of parenthesised
// subexpressions or terms, which may be followed by method invocations
// (dotrest), postcircumfix square brackets, the rest of a method call,
// or an operator expression.
method expression(acceptBlocks) {
    var sz := values.size
    util.setPosition(sym.line, sym.linePos)
    if (accept "lparen") then {
        def tmpStatementToken = statementToken
        statementToken := sym
        util.setPosition(sym.line, sym.linePos)
        next
        if (didConsume{expression(acceptBlocks)}.not) then {
            def suggestion = errormessages.suggestion.new
            def nextTok = findNextValidToken( ["rparen"] )
            if (nextTok == sym) then {
                suggestion.insert("«expression»")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextTok.prev)
                      leading(true)trailing(false)with("«expression»")
            }
            errormessages.syntaxError("parentheses must contain a valid expression.")atPosition(
                sym.line, sym.linePos)withSuggestion(suggestion)
        }
        if (sym.kind != "rparen") then {
            checkBadOperators
            def suggestion = errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken)
            errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")
                  atPosition(lastToken.line, lastToken.linePos + lastToken.size)
                  withSuggestion(suggestion)
        }
        statementToken := tmpStatementToken
        next
    } else {
        term
    }
    if (values.size > sz) then {
        dotrest(acceptBlocks)
        callrest(acceptBlocks)
        valueexpressionrest
    }
}

// Calculate the precedence of an operator. In this case, only
// multiplication and division have nontrivial precedence. Used in
// expressionrest.
method oprec(o) {
    if (o == "*") then {
        return 10
    } elseif { o == "/" } then {
        return 10
    }
    return 5
}

// Return the precedence of the operator at the top of the "ops" stack.
method toprec(ops) {
    if (ops.size > 0) then {
        var o := ops.last
        return oprec(o)
    }
    0
}


method typeexpressionrest {
    if (acceptSameLine("op")) then {
        expressionrest "type expression" recursingWith {typeexpression} blocks (noBlocks)
    }
}

method valueexpressionrest {
    if (accept "op") then {
        expressionrest "expression" recursingWith {expression(blocksOK)} blocks (blocksOK)
    }
}

method expressionrest(name) recursingWith (recurse) blocks (acceptBlocks) {
    // Process the rest of an operator expression using the shunting-yard
    // algorithm. This method uses the oprec and toprec methods above to
    // ensure the correct precedence, and treats all operators as
    // left-associative.  It is parameterised so that it
    // can be used for both type- and value- expressions.
    
    def startIndent = minIndentLevel
    var terms := [] // List of operands yet to be used
    var ops := [] // Operator stack
    var o
    var o2
    var tmp2
    var tmp := values.pop
    terms.push(tmp)
    var prec
    var allarith := true // Consists only of arithmetic operators
    var opcount := 0
    var opdtype := "" // The single operator being used in this expression
    while {
        accept("op")onLineOfLastOr(statementToken) && {sym.value != "="}
    } do {
        opcount := opcount + 1
        o := sym.value
        next
        prec := oprec(o)
        if ((o != "*") && (o != "/") && (o != "+") && (o != "-")) then {
            allarith := false
        }
        if ((opdtype != "") && (opdtype != o) && (allarith.not)) then {
            // If: this is not the first operator, it is not the same
            // as the last operator, and the expression has not been
            // entirely arithmetic, raise a syntax error.
            def suggestions = [ ]
            var suggestion := errormessages.suggestion.new
            suggestion.insert(")")afterToken(sym)
            suggestion.insert("(")beforeToken(lastToken.prev)
            suggestions.push(suggestion)
            suggestion := errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken.prev)
            suggestion.insert("(")beforeToken(lastToken.prev.prev.prev)
            suggestions.push(suggestion)
            errormessages.syntaxError("an expression containing both arithmetic " ++
                  "and non-arithmetic operators requires parentheses.") atRange (
                  lastToken.prev.prev.prev.line, lastToken.prev.prev.prev.linePos,
                  lastToken.linePos) withSuggestions (suggestions)
        }
        opdtype := o
        while {(ops.size > 0) && (prec <= toprec(ops))} do {
            // Do the shunting: for as long as the current operator
            // has lesser or equal precedence than the one on the
            // top of the stack, take the operator off the stack and
            // replace its two operands with the combined operator node.
            // This corresponds to left-associative operators only.
            o2 := ops.pop
            tmp2 := terms.pop
            tmp := terms.pop
            util.setPosition(tmp.line, tmp.linePos)
            tmp := ast.opNode.new(o2, tmp, tmp2)
            terms.push(tmp)
        }
        ops.push(o)
        if (accept "lparen") then {
            // When a parenthesis is found, take an expression from
            // *within* the parentheses and add it to the stack. Do
            // not delegate entirely to expression, because it will
            // then consume all the following operators and break
            // precedence. Possibly parenthesised expressions could
            // be allowed in term above?
            next
            if (didConsume(recurse).not) then {
                def suggestion = errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert("«{name}»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with("«{name}»")
                }
                errormessages.syntaxError("parentheses must contain a valid {name}.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
            if (sym.kind != "rparen") then {
                checkBadOperators
                def suggestion = errormessages.suggestion.new
                suggestion.insert(")")afterToken(lastToken)
                errormessages.syntaxError("an expression beginning with a '(' must end with a ')'.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
            }
            next
        } else {
            if (! tokenOnLineOfLastOr(statementToken)) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                suggestion.deleteToken(lastToken)leading(true)trailing(false)
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.insert(" «{name}»")afterToken(lastToken)
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.insert(" " ++ util.lines.at(sym.line))afterToken(lastToken)
                suggestion.deleteLine(sym.line)
                suggestions.push(suggestion)
                errormessages.syntaxError("a valid expression must follow '{lastToken.value}'. This is often caused by a new line in the middle of an expression.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestions(suggestions)
            }
            if (didNotConsume {term}) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                def nextTok = findNextValidToken( ["comma", "rparen", "rsquare", "rbrace"] )
                if (nextTok == sym) then {
                    suggestion.insert(" «{name}»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «{name}»")
                }
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
                suggestions.push(suggestion)
                errormessages.syntaxError("a valid {name} must follow '{lastToken.value}'. This is often caused by a new line in the middle of an expression.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestions(suggestions)
            }
        }

        // Regardless of where the last value came from, it may have
        // method invocations, indexes, or method call happening to it,
        // which should be applied and the result put into the operands
        // list.
        dotrest(acceptBlocks)
        callrest(acceptBlocks)
        tmp := values.pop
        terms.push(tmp)
    }
    while {ops.size > 0} do {
        // Shunt off any remaining operators at the end
        o := ops.pop
        tmp2 := terms.pop
        tmp := terms.pop
        util.setPosition(tmp.line, tmp.linePos)
        tmp := ast.opNode.new(o, tmp, tmp2)
        terms.push(tmp)
    }
    tmp := terms.pop
    values.push(tmp)
    if (terms.size > 0) then {
        errormessages.syntaxError("values left on term stack.")atPosition(sym.line, sym.linePos)
    }
    minIndentLevel := startIndent
}

method dotrest(acceptBlocks) {
    // Accept a method request starting with ".". The receiver of the request
    // is assumed to be on the values stack, and will be replaced by a
    // memberNode representing this request, consuming the dot and all the
    // parts of a following method name and its arguments.   Any following
    // dotted requests will also be parsed, by recursive invocations.

    if (acceptSameLine("dot")) then {
        def startIndent = minIndentLevel
        util.setPosition(sym.line, sym.linePos)
        var lookuptarget := values.pop
        next
        if (accept "identifier") then {
            util.setPosition(sym.line, sym.linePos)
            def dro = ast.memberNode.new(sym.value, lookuptarget)
            values.push(dro)
            next
            if (accept "dot") then {
                dotrest(acceptBlocks)
            } elseif { accept "lgeneric" } then {
                dro.generics := typeArgs
            }
            if (accept "lparen" || (acceptBlocks && accept "lbrace") ||
                  accept "num" || accept "string" || accept "lsquare") then {
                callrest(acceptBlocks)
            }
        } else {
            def suggestions = [ ]
            var suggestion := errormessages.suggestion.new
            suggestion.deleteToken(lastToken)
            suggestions.push(suggestion)
            suggestion := errormessages.suggestion.new
            suggestion.insert("«method name»")afterToken(lastToken)
            suggestions.push(suggestion)
            errormessages.syntaxError("a field or method name must follow a '.'.")atPosition(
                sym.line, sym.linePos)withSuggestions(suggestions)
        }
        minIndentLevel := startIndent
    }
}

method callrest(acceptBlocks) {
    // Accept a method request with arguments, if they are present.
    // Method requests without arguments are left as "member" AST nodes

    // The top of the values stack may be an identifierNode, which will become
    // the method name of an implicit request, or a memberNode, whose receiver
    // will become the receiver of the parsed call, and whose and nameString
    // will become the first part-name of the method name.  It may also
    // be some other expression (such as a literal), in which case there
    // can be no arguments, and there is nothing to do.
    // Leaves the stack depth unchanged.

    if (values.size == 0) then {
        return
    }
    var meth := values.pop
    if (meth.kind != "identifier") then {
        if (meth.kind != "member") then {
            values.push(meth)
            return
        }
    }
    def lnum = meth.line
    def lpos = meth.linePos
    var methn := meth.nameString
    def argumentParts = []
    def part = ast.requestPart.request(methn) withArgs [].setPositionFrom(meth)
    argumentParts.push(part)
    var foundArgs := false
    var tok := lastToken
    var genericIdents := false
    def g = meth.generics
        // when used to parse a value expression, generic arguments have already
        // been parse and are in `meth`.  When used to parse a type expression,
        // they are in the unparsed input.  This is probably a bug!
    if (false == g) then {
        if (acceptSameLine "lgeneric") then {
            genericIdents := typeArgs
        }
    } else {
        genericIdents := g
    }
    foundArgs := parseArgumentsFor(meth) into (part) acceptBlocks (acceptBlocks)
    
    if (foundArgs) then {
        def realRcvr = if (meth.isIdentifier) then {
            ast.implicit.setPositionFrom(meth)
        } else {
            meth.receiver
        }
        meth := ast.callNode.new(realRcvr, argumentParts).setPositionFrom(realRcvr)

        while {accept "identifier" onLineOfLastOr (statementToken)} do {
            // parse more parts of a multi-part request
            def argList = [ ]
            def namePart = ast.requestPart.request(sym.value) withArgs(argList).setPositionFrom(sym)
            next
            def argsFound = parseArgumentsFor(meth) into (namePart) acceptBlocks (acceptBlocks)
            if (argsFound.not) then {
                def suggestion = errormessages.suggestion.new
                suggestion.insert "(‹expression›)" afterToken (lastToken)
                def more = if (indentHasIncreased) then {
                    "  The indentation tells me that this is a continuation of" ++
                        " the previous line; is that what you intended?"
                } else { "" }
                def reqStart = ast.line (lnum) column (lpos)
                def reqEnd = ast.line (lastToken.line) column (lastToken.endPos)
                def reqRange = ast.start (reqStart) end (reqEnd)
                errormessages.syntaxError("a multi-part method request must end with an argument list," ++
                    " either parenthesized or self-delimiting." ++ more)
                        atRange(reqRange) withSuggestion (suggestion)
            }
            argumentParts.addLast(namePart)
        }
        meth.end := ast.line (lastLine) column (lastToken.endPos)
        // we do this indside the if, because outside meth might be an
        // identifierNode or a memberNode
    }
    meth.generics := genericIdents
    values.push(meth)
    dotrest(acceptBlocks)
}

method parseArgumentsFor(meth) into (part) acceptBlocks (acceptBlocks) {
    // `meth` is a memberNode or an identifier.
    // Parses the arguments for `part`, a requestPart of a method request.
    // If arguments are present, adds them to `part.args` and answers true.
    // Answers false if no arguments are present.


    var tok := lastToken
    if (acceptSameLine "lparen") then {
        tok := sym
        parenthesizedArgs(part) startingWith (tok)
        true
    } elseif { acceptBlocks.not && { accept "lbrace" onLineOf (statementToken) } } then {
        false
    } elseif { acceptArgumentOnLineOf (tok) } then {
        tok := sym
        term
        part.args.push(values.pop)
        true
    } else {
        false
    }
}

method parenthesizedArgs(part) startingWith (tok) {
    next
    if (didConsume {expression(blocksOK)}) then {
        while {accept "comma"} do {
            part.args.push(values.pop)
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rparen"] )
                if (nextTok == sym) then {
                    suggestion.insert " «expression»" afterToken (lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)
                        leading (true) trailing (false) with " «expression»"
                }
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
                suggestions.push(suggestion)
                errormessages.syntaxError("an argument list must have an expression after a ','.")
                      atPosition(sym.line, sym.linePos)
                      withSuggestions(suggestions)
            }
        }
        part.args.push(values.pop)
    }
    if (sym.kind != "rparen") then {
        checkBadOperators
        def suggestion = errormessages.suggestion.new
        suggestion.insert(")")afterToken(lastToken)
        def rng = ast.start (ast.line (tok.line) column (tok.linePos))
                        end (ast.line (lastToken.line) column (lastToken.linePos + lastToken.size))
        errormessages.syntaxError "an argument list beginning with a '(' must end with a ')'."
              atRange (rng) withSuggestion (suggestion)
    }
    if (sym.line == part.line) then {
        part.lineLength := sym.linePos - part.linePos
    }
    next
}

method typeArgs {
    // Parses one or more type arguments, if present, and returns them as a list.

    def args = [ ]
    if (sym.kind != "lgeneric") then { return args }
    def startToken = sym
    next
    while {didConsume{typeArg}} do {
        args.add(values.pop)
        if (sym.kind == "comma") then { next }
    }
    if (sym.kind != "rgeneric") then {
        def suggestion = errormessages.suggestion.new
        suggestion.insert "⟦" afterToken(lastToken)
        def suggestion2 = errormessages.suggestion.new
        suggestion2.insert " " beforeToken(startToken)
        def suggestions = [suggestion, suggestion2]
        errormessages.syntaxError "a method request containing a '⟦' must have a matching '⟧'. "
              atPosition(lastToken.line, lastToken.linePos + lastToken.size)
              withSuggestions(suggestions)
    }
    next
    return args
}

method typeArg {
    // Parses a single type argument, and leaves it on the values stack.
    // TODO: 'identifier' could be a dotted identifier, 
    //        or perhaps a type expression?

    if (accept "identifier") then {
        identifier
        if (sym.kind == "lgeneric") then {
            values.push(ast.genericNode.new(values.pop, typeArgs))
        }
    } else {
        dotypeLiteral
    }
}

method errorDefNoName {
    def suggestion = errormessages.suggestion.new
    def nextToken = findNextToken({ t -> (t.kind == "op")
        && (t.value == "=") && (t.line == sym.line)})
    if (false == nextToken) then {
        suggestion.insert(" «name» =")afterToken(lastToken)
    } elseif { nextToken == sym } then {
        suggestion.insert(" «name»")afterToken(lastToken)
    } else {
        suggestion.replaceTokenRange(sym, nextToken.prev)
              leading(false)trailing(true)with("«name» ")
    }
    errormessages.syntaxError("a definition must have a name, '=', " ++
          "and a value after the 'def'.") atPosition(sym.line, sym.linePos)
          withSuggestion(suggestion)
}

method errorDefNoExpression {
    def suggestion = errormessages.suggestion.new
    def nextTok = findNextValidToken( [ ] )
    if (nextTok == sym) then {
        suggestion.insert(" «expression»")afterToken(lastToken)
    } else {
        suggestion.replaceTokenRange(sym, nextTok.prev)
              leading(true)trailing(false)with(" «expression»")
    }
    errormessages.syntaxError("a definition must have a value after the '='.")
          atPosition(lastToken.line, lastToken.linePos + lastToken.size)
          withSuggestion(suggestion)
}

method errorDefUsesAssign(defTok) {
    def suggestions = [ ]
    var suggestion := errormessages.suggestion.new
    suggestion.replaceToken(sym)with("=")
    suggestions.push(suggestion)
    suggestion := errormessages.suggestion.new
    suggestion.replaceToken(defTok)with("var")
    suggestions.push(suggestion)
    errormessages.syntaxError("a definition must use '=' instead of ':='. " ++
        "A variable declaration uses 'var' and ':='.")atRange(
        sym.line, sym.linePos, sym.linePos + 1) withSuggestions(suggestions)
}

method errorDefMissingRhs(defTok) {
    def suggestions = [ ]
    var suggestion := errormessages.suggestion.new
    suggestion.insert(" = «expression»")afterToken(lastToken)
    suggestions.push(suggestion)
    suggestion := errormessages.suggestion.new
    suggestion.replaceToken(defTok)with("var")
    suggestions.push(suggestion)
    errormessages.syntaxError("a definition must have '=' and a value after the name. "
        ++ "A variable declaration does not require a value but uses 'var', not 'def'.")
        atPosition(sym.line, sym.linePos) withSuggestions(suggestions)
}

method defdec {
    // Accept definition of a constant

    if (acceptKeyword "def") then {
        def startIndent = minIndentLevel
        def line = sym.line
        def pos = sym.linePos
        def defTok = sym
        next
        if (sym.kind != "identifier") then {
            errorDefNoName
        }
        pushidentifier
        var val := false
        var name := values.pop
        name.isBindingOccurrence := true
        var dtype := optionalTypeAnnotation
        def anns = doannotation
        if (accept("op") && (sym.value == "=")) then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                errorDefNoExpression
            }
            val := values.pop
        } elseif { accept "bind" } then {
            errorDefUsesAssign(defTok)
        } else {
            errorDefMissingRhs(defTok)
        }
        util.setPosition(defTok.line, defTok.linePos)
        var o := ast.defDecNode.new(name, val, dtype)
        if (false != anns) then { o.annotations.addAll(anns) }
        o.startToken := defTok
        values.push(o)
        reconcileComments
        minIndentLevel := startIndent
    }
}

method vardec {
    // Accept a var declaration

    if (acceptKeyword "var") then {
        def startIndent = minIndentLevel
        def line = sym.line
        def pos = sym.linePos
        def varTok = sym
        next
        if (sym.kind != "identifier") then {
            def suggestion = errormessages.suggestion.new
            def nextToken = findNextToken({ t -> (t.kind == "bind")
                && (t.line == sym.line)})
            if ((false == nextToken) || {nextToken == sym}) then {
                suggestion.insert(" «name»")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextToken.prev)
                      leading(false)trailing(true)with("«name» ")
            }
            errormessages.syntaxError "a variable declaration must have a name after the 'var'."
                  atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
        }
        pushidentifier
        var val := false
        var name := values.pop
        name.isBindingOccurrence := true
        def dtype = optionalTypeAnnotation
        def anns = doannotation
        if (accept "bind") then {
            next
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                def nextTok = findNextValidToken( [ ] )
                if (nextTok == sym) then {
                    suggestion.insert(" «expression»")afterToken(lastToken)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)
                          leading(true)trailing(false)with(" «expression»")
                }
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
                suggestions.push(suggestion)
                errormessages.syntaxError("a variable declaration must have a value after the ':='. "
                    ++ "A variable without a value can be declared with 'var' followed only by the variable name.")atPosition(
                    lastToken.line, lastToken.linePos + lastToken.size)withSuggestions(suggestions)
            }
            val := values.pop
        } else {
            if (accept("op") && (sym.value == "=")) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                suggestion.replaceToken(sym)with(":=")
                suggestions.push(suggestion)
                suggestion := errormessages.suggestion.new
                suggestion.replaceToken(varTok)with("def")
                suggestions.push(suggestion)
                errormessages.syntaxError("a variable declaration must use ':=' instead of '='. A definition uses 'def' and '='.")
                    atRange(sym.line, sym.linePos, sym.linePos)
                    withSuggestions(suggestions)
            }
        }
        util.setPosition(line, pos)
        def o = ast.varDecNode.new(name, val, dtype)
        if (false != anns) then { o.annotations.addAll(anns) }
        values.push(o)
        reconcileComments
        minIndentLevel := startIndent
    }
}

method doarray {
    // Accept a square-bracketed collection literal like [1,2,3].

    if (accept "lsquare") then {
        def lSq = sym
        next
        var tmp
        var params := []
        if (didConsume {expression(blocksOK)}) then {
            while {accept("comma")} do {
                tmp := values.pop
                params.push(tmp)
                next
                if (didNotConsume {expression(blocksOK)}) then {
                    def suggestions = [ ]
                    var suggestion := errormessages.suggestion.new
                    def nextTok = findNextValidToken( ["rsquare"] )
                    if (nextTok == sym) then {
                        suggestion.insert(" «expression»")afterToken(lastToken)
                    } else {
                        suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «expression»")
                    }
                    suggestions.push(suggestion)
                    suggestion := errormessages.suggestion.new
                    suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
                    suggestions.push(suggestion)
                    errormessages.syntaxError("a collection must contain zero or more expressions separated by commas.")
                        atPosition(sym.line, sym.linePos) withSuggestions(suggestions)
                }
            }
            tmp := values.pop
            params.push(tmp)
        }
        if (sym.kind != "rsquare") then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert("]")afterToken(lastToken)
            errormessages.syntaxError("a collection beginning with a '[' must end with a ']'.")atPosition(
                lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
        }
        def o = ast.arrayNode.new(params).setPositionFrom(lSq)
        values.push(o)
        next
    }
}

method dodialect {
    // Parses "dialect «quoted-string»"

    if (acceptKeyword "dialect") then {
        next
        if (sym.kind != "string") then {
            def suggestion = errormessages.suggestion.new
            var errorPos
            if ((sym.kind == "identifier") && (sym.line == lastToken.line)) then {
                suggestion.replaceToken(sym)with("\"{sym.value}\"")
                errorPos := sym.linePos
            } else {
                suggestion.insert(" \"«dialect name»\"")afterToken(lastToken)
                errorPos := lastToken.linePos + lastToken.size + 1
            }
            errormessages.syntaxError("a dialect statement must have the name " ++
                "of the dialect in quotes after the word 'dialect'.")
                atPosition(lastToken.line, errorPos)withSuggestion(suggestion)
        }
        if (values.isEmpty) then {
            def dn = ast.dialectNode.fromToken(sym)
            next
            if (moduleObject.theDialect.line == 0) then {
                moduleObject.theDialect := dn
            } else {
                errormessages.syntaxError("at most one dialect statement may appear in a module.")
                  atLine(lastToken.line)
            }
        } else {
            errormessages.syntaxError("a dialect statement must be at the start of the module.")
                  atLine(lastToken.line)
        }
    }
}

method inheritOrUse {
    // Parses "inherit «object expression»"
    if ( acceptSeparator ) then { separator }
    if (! accept "keyword") then { return }
    if ((sym.value == "inherit") || (sym.value == "use")) then {
        statementToken := sym
        def btok = sym
        next
        if (didNotConsume {expression(blocksOK)}) then {
            def suggestions = [ ]
            var suggestion := errormessages.suggestion.new
            def nextTok = findNextValidToken( ["rsquare"] )
            if (nextTok == sym) then {
                suggestion.insert(" «parent»")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «parent»")
            }
            suggestions.push(suggestion)
            suggestion := errormessages.suggestion.new
            suggestion.deleteTokenRange(lastToken, nextTok.prev)leading(true)trailing(false)
            suggestions.push(suggestion)
            var msg := "The {btok.value} keyword must be followed by an expression that creates "
            if (btok.value == "use") then {
                msg := msg ++ "the trait being used."
            } else {
                msg := msg ++ "the object being inherited."
            }
            errormessages.syntaxError(msg)
                atPosition(lastToken.line, lastToken.linePos + lastToken.size + 1)
                withSuggestions(suggestions)
        }
        util.setPosition(btok.line, btok.linePos)
        def inhNode = ast.inheritNode.new(values.pop)
        if (btok.value == "use") then {
            inhNode.isUse := true
        }
        while { inheritModifier(inhNode) onLineOf(btok) } do { }
        values.push(inhNode)
    }
}

method inheritModifier(node) onLineOf(startToken) {
    // parse an alias or exclude modifier on an `inherit` clause
    if (! accept "keyword" onLineOf(startToken) ) then { 
        return false
    }
    if (sym.value == "alias") then { 
        parseAlias(node) 
    } elseif {sym.value == "exclude"} then {
        parseExclude(node)
    } else {
        false
    }
}

method parseAlias(node) {
    next    // skip the alias keyword
    def newMeth = methodsignature(true)
    if (accept "op" && (sym.value == "=")) then {
        next
        def oldMeth = methodsignature(true).appliedOccurence
        if (newMeth.numParams ≠ oldMeth.numParams) then {
            errormessages.syntaxError "a method and its alias must have the same number of parameters"
                atRange (newMeth.line, newMeth.linePos, oldMeth.endPos)
        }
        node.addAlias (newMeth.asIdentifier) for (oldMeth.asIdentifier)
    } else {
        errormessages.syntaxError ("an alias modifier must take the form " ++
            "'‹newMethodName› = ‹oldMethodName›'")
            atPosition (lastToken.line, lastToken.linePos + lastToken.size)
    }
    return true
}
method parseExclude(node) {
    next    // skip the exclude keyword
    def excludedMeth = methodsignature(true).appliedOccurence
    node.addExclusion (excludedMeth.asIdentifier)
    return true
}

method doobject {
    // Parse an object constructor.
    // this method is called doobject because "object" is a keyword

    if (acceptKeyword "object") then {
        next
        parseObjectConstructorBody "an object constructor" 
            startingWith (lastToken) after "'object'"
    }
}

method parseObjectConstructorBody(constructName) startingWith (btok) after (prev) {
    // Parse the body of an object constructor, leaving the node on the
    // values stack.  Common code for parsing object and class
    // bodies; constructName says which, so that error messages are correct.
    // btok is the keyword token that started the construct: class, object, or trait.
    def localMinIndentLevel = minIndentLevel
    def anns = doannotation
    if (sym.kind != "lbrace") then {
        def suggestion = errormessages.suggestion.new
        def nextTok = findNextToken { t -> t.kind == "rbrace" }
        if (false == nextTok) then {
            suggestion.insert(" \{}")afterToken(lastToken)
        } else {
            suggestion.insert(" \{")afterToken(lastToken)
        }
        errormessages.syntaxError "{constructName} must have a '\{' after the {prev}."
            atPosition(lastToken.line, lastToken.linePos + lastToken.size)
            withSuggestion(suggestion)
    }
    next
    if (sym.line == statementToken.line) then {
        minIndentLevel := sym.linePos - 2
    } else {
        minIndentLevel := statementToken.indent + 2
    }
    def originalValues = values
    values := []
    var superObject := false
    def usedTraits = []
    var inPreamble := true  // => processing inherit and use statements
    while {(accept "rbrace").not && {sym.kind != "eof"}} do {
        pushComments
        if (didConsume {inheritOrUse}) then {
            def parentNode = values.pop
            if (inPreamble) then {
                if (parentNode.isUse) then {
                    usedTraits.add(parentNode)
                } elseif { usedTraits.isEmpty } then {
                    superObject := parentNode
                } else {
                    errormessages.syntaxError("'inherit' must come " ++
                        "before 'use' in {constructName}")
                        atRange(parentNode.line, parentNode.linePos,
                        parentNode.linePos + 7)
                }
            } else {
                errormessages.syntaxError("'{parentNode.statementName}' must " ++
                    "come at the start of {constructName}")
                    atRange(parentNode.line, parentNode.linePos,
                            parentNode.linePos + parentNode.statementName.size)
            }
        } elseif { didConsume {methoddec} } then {
            inPreamble := false
        } elseif { didConsume {statement} } then {
            inPreamble := false
        } else {
            errormessages.syntaxError("unexpected symbol '{sym.value}' in body " ++
                "of of {constructName}")
                atRange(sym.line, sym.linePos, sym.endPos)
        }
    }
    def body = values
    values := originalValues
    next
    def objNode = ast.objectNode.new(body, superObject).setPositionFrom(btok)
    if (false != anns) then { objNode.annotations.addAll(anns) }
    objNode.usedTraits := usedTraits
    values.push(objNode)
    minIndentLevel := localMinIndentLevel
}

method doclass {
    // Accepts a class declaration.
    // Class declarations were formerly of the form:
    //
    //   class objName.methodName (param1, param2) {
    //     inherit <expr>
    //     var x
    //     method y(z) { … }
    // }
    // Such declarations are no longer supported, and produce an
    // error message starting with "dotted classes are no longer supported"
    //
    // Classes are now of the form:
    //
    // class methodName (param1, param2) {
    //     inherit <expr>
    //     var x
    //     method y(z) { … }
    // }
    //
    // A class is compiled into a methodNode that contains
    // an objectNode, i.e., it is treated as syntactic sugar for
    //
    // method methodName (param1, param2) {
    //     object {
    //         inherit <expr>
    //         var x
    //         method y(z) { … }
    //     }
    // }
    //
    // Arguably, this is wrong.  Perhaps the parser should create classNodes,
    // which would later be removed by the AST re-writing step?
    // So that syntactic-classes can be found if necessary, methodNodes
    // generated by the class syntax answer true to `inClass`.

    def btok = sym
    next
    def localMinIndentLevel = minIndentLevel
    if (sym.kind != "identifier") then {
        def suggestions = [ ]
        if (sym.kind == "lbrace") then {
            var suggestion := errormessages.suggestion.new
            suggestion.insert(" «class name».new")afterToken(lastToken)
            suggestions.push(suggestion)
            suggestion := errormessages.suggestion.new
            suggestion.replaceToken(lastToken)with("object")
            suggestions.push(suggestion)
        } else {
            def suggestion = errormessages.suggestion.new
            suggestion.insert(" «class name».new \{}")afterToken(lastToken)
            suggestions.push(suggestion)
        }
        errormessages.syntaxError "a class must have a name after the keyword 'class'."
            atPosition(lastToken.line, lastToken.linePos + lastToken.size + 1)
            withSuggestions(suggestions)
    }
    if (tokens.first.kind == "dot") then {
        errormessages.syntaxError("dotted classes are no longer supported. " ++
                "Consider using a class, or a class inside an object constructor.")
                atPosition(tokens.first.line, tokens.first.linePos)
    }
    def meth = methodsignature(false)
    meth.setPositionFrom(btok)
    parseObjectConstructorBody "a class" startingWith (btok) after "method header"
    def objNode = values.pop
    meth.body := [objNode]
    meth.usesClassSyntax := true
    meth.annotations.addAll(objNode.annotations)  // TODO: sort this out!
        // In a class declaration, there is just one place for annotations.
        // These might include annotations on the method (such as
        // confidential), and annotations on the object (such as immutable)
    objNode.name := meth.canonicalName
    if (btok.value == "class") then {
        objNode.inClass := true
    } elseif { btok.value == "trait" } then {
        objNode.inTrait := true
    }
    values.push(meth)
    reconcileComments
    minIndentLevel := localMinIndentLevel
    separator
}

method dofactoryMethod {
    // Accept a factory method declaration
    if ((acceptKeyword "factory") && { tokens.first.kind == "keyword" } && {
        tokens.first.value == "method"
    }) then {
        def btok = sym
        next
        errormessages.syntaxError("the keyword combination 'factory method' is " ++
                "no longer supported. Use 'class' instead.")
                atRange(btok.line, btok.linePos, sym.line, sym.endPos)
                withSuggestions []
    }
}

method methoddec {
    // Parse a method declaration

    if (acceptKeyword "method") then {
        def btok = sym
        statementToken := sym
        next
        def methNode = methodsignature(false).setPositionFrom(btok)
        var localMin
        def anns = doannotation
        def originalValues = values
        values := []
        if (accept "lbrace") then {
            next
            localMin := minIndentLevel
            // sym is now the first token in the method body
            if (sym.line == btok.line) then {
                // first statement is on the same line as `method` keyword
                minIndentLevel := sym.linePos - 1
            } else {
                minIndentLevel := btok.indent + 2
            }
            while { didConsume { statement } } do { }
                // The body is a sequence of statements; the method ends
                // when no further statement is found.
            if (sym.kind != "rbrace") then {
                def suggestion = errormessages.suggestion.new
                def closingBrace = findClosingBrace(btok, false)
                if (closingBrace.found.not) then {
                    if (sym.kind == "eof") then {
                        errormessages.syntaxError("end of program " ++
                            "found while searching for the '}' to close " ++
                              "a method declaration.")
                                atPosition(sym.line, sym.linePos)
                    }
                    if (closingBrace.tok == sym) then {
                        suggestion.insert("}")afterToken(lastToken)
                    } else {
                        suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                    }
                }
                suggestion.deleteToken(sym)
                errormessages.syntaxError("a method must end with a '}'.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
            next
            minIndentLevel := localMin
        } else {
            def suggestion = errormessages.suggestion.new
            def closingBrace = findClosingBrace(btok, true)
            if (closingBrace.found.not) then {
                if (closingBrace.tok == lastToken) then {
                    suggestion.insert(" \{}")afterToken(lastToken)andTrailingSpace(true)
                } else {
                    suggestion.addLine(closingBrace.tok.line + 0.1, "}")
                    suggestion.insert(" \{")afterToken(lastToken)andTrailingSpace(true)
                }
            } else {
                suggestion.insert(" \{")afterToken(lastToken)andTrailingSpace(true)
            }
            errormessages.syntaxError("a method must have a '\{' after the name.")atPosition(
                lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
        }
        methNode.body := values
        values := originalValues
        util.setline(btok.line)
        if (false != anns) then { methNode.annotations.addAll(anns) }
        values.push(methNode)
        pushComments
        separator
        reconcileComments
        pushComments
    }
}

method separator {
    pushComments
    if (acceptSeparator) then {
        next
    } elseif { (accept "eof") || { accept "rbrace" } } then {
        // do nothing
    } else {
        errormessages.syntaxError "statments must be separated by newlines (or semicolons)"
                    atPosition(
                lastToken.line, lastToken.linePos + lastToken.size)
    }
}

method methodDecRest(tm, sameline) {
    // Process the remainder of a method header. These follow
    // mostly the same rules as calls, but aren't strictly enforced to be on
    // a single line (because they are ended by "{"). 
    //
    // tm is a methodNode.  This method modifies tm.params in place.

    var signature := tm.signature
    while {(!sameline && accept("identifier")) || acceptSameLine("identifier")} do {
        pushidentifier
        def part = ast.signaturePart.partName(values.pop.nameString)
        if ((accept("lparen")).not) then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert("()")afterToken(lastToken)
            errormessages.syntaxError("the declaration of a method with multiple " ++
                  "parameter lists must have parentheses around each parameter list.")
                  atPosition(sym.line, sym.linePos)withSuggestion(suggestion)
        }
        next
        var comma := false
        while {
            accept("identifier") || (accept("op") && (sym.value == "*"))
        } do {
            if (accept "op") then {
                next
                errormessages.syntaxError("variable length parameters (parameters prefixed by '*') are no longer part of Grace.  Consider making {sym.value} an Iterable.")
                    atPosition(lastToken.line, lastToken.linePos)
            }
            pushidentifier
            def nxt = values.pop
            nxt.isBindingOccurrence := true
            nxt.dtype := optionalTypeAnnotation
            part.params.push(nxt)
            if (accept "comma") then {
                comma := sym
                next
            }
        }
        if (sym.kind != "rparen") then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert(")")afterToken(lastToken)
            errormessages.syntaxError("a part of a multi-part method beginning with a '(' must end with a ')'.")atPosition(
                lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
        }
        next
        signature.push(part)
    }
}

method optionalTypeAnnotation {
    // Accept a type annotation if present.
    // Returns the type, or false if there is no annotation
    if (accept "colon") then {
        next
        if (didConsume { typeexpression }) then {
            values.pop
        } else {
            checkBadTypeLiteral
            def suggestions = [ ]
            var suggestion := errormessages.suggestion.new
            suggestion.insert(" «type name»")afterToken(lastToken)
            suggestions.push(suggestion)
            suggestion := errormessages.suggestion.new
            suggestion.deleteToken(lastToken)leading(true)trailing(false)
            suggestions.push(suggestion)
            errormessages.syntaxError("a type name or type expression must follow ':'.")atPosition(
                sym.line, sym.linePos)withSuggestions(suggestions)
        }
    } else {
        false
    }
}

method methodsignature(sameline) {
    // Accept a method signature
    if ((! acceptKeyword "prefix") && (sym.kind != "identifier") && (sym.kind != "op")) then {
        def suggestion = errormessages.suggestion.new
        suggestion.insert(" «method name»")afterToken(lastToken)
        errormessages.syntaxError("a method name must start with an identifier, or be an operator.")
            atPosition(lastToken.line, lastToken.linePos + lastToken.size + 1)
                withSuggestion(suggestion)
    }
    def startToken = sym
    def part = ast.signaturePart.partName(startToken.value)
    next
    def result = ast.methodNode.new( [ part ], [], false)
    if ((startToken.value == "[") && {sym.kind == "rsquare"}) then {
        errormessages.syntaxError("methods named '[]' and '[]:=' are no longer part of Grace.")
            atRange(lastToken.line, lastToken.linePos, sym.linePos)
    }
    if (accept "lgeneric") then { result.typeParams := typeparameters }
    if (accept "bind") then {
        part.name := part.name ++ ":="
        next
    } elseif { accept "op"  && (startToken.value == "prefix") } then {
        part.name := part.name ++ sym.value
        next
    }
    if (accept "lparen") then {
        def lparen = sym
        next
        var id
        var comma := false
        while {
            accept("identifier") || (accept("op") && (sym.value == "*"))
        } do {
            // Parse the parameter list, including optional dtype
            // annotations.
            if (accept "op") then {
                next
                errormessages.syntaxError("variable length parameters (parameters prefixed by '*') are no longer part of Grace.  Consider making {sym.value} an Iterable.")
                    atPosition(lastToken.line, lastToken.linePos)
            }
            pushidentifier
            id := values.pop
            id.isBindingOccurrence := true
            id.dtype := optionalTypeAnnotation
            part.params.push(id)
            if (accept "comma") then {
                comma := sym
                next
            } elseif { sym.kind != "rparen" } then {
                if (sym.kind != "rparen") then {
                    def suggestion = errormessages.suggestion.new
                    suggestion.insert(")")afterToken(lastToken)
                    errormessages.syntaxError("a part of a method beginning with a '(' must end with a ')'.")atPosition(
                        lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
                }
            }
        }
        if (sym.kind != "rparen") then {
            def suggestion = errormessages.suggestion.new
            def rparen = findNextToken({ t -> (t.kind == "rparen") && (t.line == lastToken.line) })
            if (false == rparen) then {
                suggestion.replaceToken(lastToken)with(")")
            } else {
                suggestion.deleteToken(sym)
            }
            errormessages.syntaxError("a part of a method beginning with a '(' must end with a ')'.")atRange(
                lastToken.line, lastToken.linePos, lastToken.linePos)withSuggestion(suggestion)
        }
        if (sym.line == part.line) then {
            part.lineLength := sym.linePos - part.linePos
        }
        next
        if ((!sameline && accept("identifier")) ||
            acceptSameLine("identifier")) then {
            // The presence of an identifier here means
            // a multi-part method name.
            methodDecRest(result, sameline)
        }
    }
    if (accept "arrow") then {
        // parse the return type
        next
        if (didNotConsume {typeexpression} ) then {
            errormessages.syntaxError("after an arrow, write the method's return " ++
                  "type. If you don't want to state the return type, omit the arrow.")
                  atRange(sym.line, sym.linePos, sym.endPos)
        }
        result.dtype := values.pop
    }
    result
}

method typeparameters {
    def openBracket = sym
    next
    def typeIds = [ ]
    while {accept("identifier")} do {
        identifier
        def id = values.pop
        id.isBindingOccurrence := true
        typeIds.push(id)
        if (accept "comma") then {
            next
        }
    }
    typeIds.do { each -> each.isBindingOccurrence := true }
    def result = ast.typeParametersNode.new(typeIds).setPositionFrom(openBracket)
    if (sym.kind != "rgeneric") then {
        def suggestion = errormessages.suggestion.new
        suggestion.insert "⟧" afterToken (lastToken)
        errormessages.syntaxError("a list of type parameters starting with '⟦' must end with '⟧'.")atPosition(
            lastToken.line, lastToken.linePos + lastToken.size)withSuggestion(suggestion)
    }
    next
    result
}

method doimport {
    // Accept an import statement, which has the form
    //      import ‹string› as ‹identifier›:‹type expression› is ‹annotation›
    if (acceptKeyword "import") then {
        def importSym = sym
        next
        if (sym.kind != "string") then {
            var suggestion := errormessages.suggestion.new
            var errorPos
            if ((sym.kind == "identifier") && (sym.line == lastToken.line)) then {
                suggestion.replaceToken(sym)with("\"{sym.value}\"")
                errorPos := sym.linePos
            } else {
                suggestion.insert(" \"«module name»\"")afterToken(lastToken)
                errorPos := lastToken.linePos + lastToken.size + 1
            }
            errormessages.syntaxError("an import statement must have the name of the module to be imported (in quotes), 'as', and an identifier after 'import'.")atPosition(
                lastToken.line, errorPos)withSuggestion(suggestion)
        }
        pushstring
        def p = values.pop
        if (! acceptKeyword "as") then {
            var suggestion := errormessages.suggestion.new
            if ((sym.kind == "identifier") && (sym.line == lastToken.line)) then {
                suggestion.insert(" as")afterToken(lastToken)
            } else {
                suggestion.insert(" as {p.value}")afterToken(lastToken)
            }
            errormessages.syntaxError("an import statement must have 'as', followed by an identifier, after the name of the module in quotes.")atPosition(
                lastToken.line, lastToken.linePos + lastToken.size + 1)withSuggestion(suggestion)
        }
        next
        if (sym.kind != "identifier") then {
            var suggestion := errormessages.suggestion.new
            var errorPos
            if ((sym.kind == "string") && (sym.line == lastToken.line)) then {
                suggestion.replaceToken(sym)with("{sym.value}")
                errorPos := sym.linePos
            } else {
                suggestion.insert(" {p.value}")afterToken(lastToken)
                errorPos := lastToken.linePos + lastToken.size + 1
            }
            errormessages.syntaxError("an import statement must have an identifier after 'as'.")atPosition(
                lastToken.line, errorPos)withSuggestion(suggestion)
        }
        pushidentifier
        def name = values.pop
        name.isBindingOccurrence := true
        def dtype = optionalTypeAnnotation
        def o = ast.importNode.new(p.value, name, dtype).setPositionFrom(importSym)
        def anns = doannotation
        if (false != anns) then { o.annotations.addAll(anns) }
        values.push(o)
        reconcileComments
    }
}

method doreturn {
    // Accept a return statement; 'return' is followed by an optional expression.
    if (acceptKeyword "return") then {
        def retTok = sym
        next
        var retval
        if ((tokenOnSameLine) && {accept("rbrace").not}) then {
            if (didNotConsume {expression(blocksOK)}) then {
                def suggestions = [ ]
                var suggestion := errormessages.suggestion.new
                def nextTok = findNextValidToken( ["rbrace"] )
                if (nextTok == sym) then {
                    suggestion.insert(" «expression»")afterToken(lastToken)
                    suggestions.push(suggestion)
                    suggestion := errormessages.suggestion.new
                    suggestion.deleteToken(sym)leading(true)trailing(false)
                } else {
                    suggestion.replaceTokenRange(sym, nextTok.prev)leading(true)trailing(false)with(" «expression»")
                    suggestions.push(suggestion)
                    suggestion := errormessages.suggestion.new
                    suggestion.deleteTokenRange(sym, nextTok.prev)leading(true)trailing(false)
                }
                suggestions.push(suggestion)
                errormessages.syntaxError ("a return statement must have " ++
                    "an expression or a newline after the word 'return'.")
                    atRange (sym.line, sym.linePos, sym.endPos)
                    withSuggestions (suggestions)
            }
            retval := values.pop
        } else {
            retval := ast.identifierNode.new("done", false).setStart(ast.noPosition)
            retval.end := ast.noPosition
        }
        util.setPosition(retTok.line, retTok.linePos)
        var o := ast.returnNode.new(retval)
        values.push(o)
    }
}

method domethodtype {
    // parses a method in a type literal
    def methodTypeTok = sym
    var methNode := methodsignature(true)
    var dtype := methNode.dtype
    if (false == methNode.dtype) then {
        dtype := ast.identifierNode.new("Done", false)
    }
    def o = ast.methodTypeNode.new(methNode.signature, dtype)
                                            .setPositionFrom(methodTypeTok)
    o.typeParams := methNode.typeParams
    values.push(o)
    reconcileComments
    if (acceptSeparator) then {
        next
    } else {
        if (!accept("rbrace")) then {
            if (lastToken.line == sym.line) then {
                def suggestion = errormessages.suggestion.new
                def newLine = util.lines.at(sym.line).substringFrom(1)to(lastToken.linePos - 1) ++ sym.value
                suggestion.addLine(sym.line + 0.1, newLine)
                suggestion.deleteToken(sym)leading(true)trailing(true)
                errormessages.syntaxError("methods in a type literal must be on separate lines, or separated by semicolons.")atPosition(
                    sym.line, sym.linePos)withSuggestion(suggestion)
            }
        }
    }
}

method dotypeLiteral {
    // parses an interface literal between braces, with optional
    // leading 'type' or 'interface' keyword.
    def typeLiteralTok = sym
    if (acceptKeyword "type" or "interface") then {
        next
        if (!accept("lbrace")) then {
            def suggestion = errormessages.suggestion.new
            suggestion.replaceToken(sym) with("\{")
            errormessages.syntaxError "{typeLiteralTok.value} literals must open with a brace."
                atPosition(sym.line, sym.linePos) withSuggestion(suggestion)
            return
        }
    }
    if (accept "lbrace") then {
        def meths = []
        def types = []
        def mc = auto_count
        auto_count := auto_count + 1
        next
        skipSeparators
        while { accept("rbrace").not } do {
            if (acceptKeyword "type") then {
                typedec
                types.push(values.pop)
            } else {
                domethodtype
                meths.push(values.pop)
            }
        }
        next
        util.setPosition(typeLiteralTok.line, typeLiteralTok.linePos)
        def t = ast.typeLiteralNode.new(meths, types)
        values.push(t)
    }
}

method typedec {
    // Accept a declaration: 'type = <type expression>'
    if (acceptKeyword "type") then {
        def line = sym.line
        def pos = sym.linePos
        next
        if (sym.kind != "identifier") then {
            def suggestion = errormessages.suggestion.new
            suggestion.insert(" «type name»")afterToken(lastToken)
            errormessages.syntaxError("a type declaration must have a name after the 'type'.")atPosition(
                lastToken.line, lastToken.linePos + lastToken.size + 1)withSuggestion(suggestion)
        }
        pushidentifier
        util.setPosition(line, pos)
        def nt = ast.typeDecNode.new(values.pop, false)
        if (accept "lgeneric") then { nt.typeParams := typeparameters }
        nt.name.isBindingOccurrence := true
        def anns = doannotation
        if ((sym.kind != "op") || (sym.value != "=")) then {
            var suggestion := errormessages.suggestion.new
            def nextTok = findNextToken { t ->
                (t.kind == "lbrace") || (t.kind == "keyword")
            }
            if ((false == nextTok) || {nextTok == sym}) then {
                suggestion.insert(" =")afterToken(lastToken)
            } else {
                suggestion.replaceTokenRange(sym, nextTok.prev)with("=")
            }
            errormessages.syntaxError "a type declaration must have an '=' after the type name."
                  atPosition(lastToken.line, lastToken.linePos + lastToken.size + 1)
                  withSuggestion(suggestion)
        }
        next
        // Special case for type Literals without leading 'type' keyword.
        if (accept "lbrace") then {
            dotypeLiteral
        } else {
            expression(noBlocks)
        }
        nt.value := values.pop
        if (false != anns) then {
            nt.annotations.addAll(anns)
        }
        values.push(nt)
        reconcileComments
    }
}

method statement {
    // Accept a statement. A statement is any of the above that may exist
    // at the top level, and includes expressions.
    // A statement may also be a bind statement x := y, which creates a
    // bind AST node out of the expressions on either side (which at this point
    // can be any arbitrary expression).

    skipSeparators
    statementIndent := sym.indent
    statementToken := sym
    def btok = sym
    pushComments
    if (accept "keyword") then {
        if (sym.value == "var") then {
            vardec
        } elseif { sym.value == "def" } then {
            defdec
        } elseif { sym.value == "import" } then {
            doimport
        } elseif { sym.value == "dialect" } then {
            dodialect
        } elseif { sym.value == "type" } then {
            typedec
        } elseif { sym.value == "class" } then {
            doclass
        } elseif { sym.value == "trait" } then {
            doclass
        } elseif { sym.value == "factory" } then {
            dofactoryMethod
        } elseif { sym.value == "return" } then {
            doreturn
        } else {
            expression(blocksOK)
        }
    } else {
        if (didConsume {expression(blocksOK)}) then {
            if (((values.last.kind == "identifier")
                || (values.last.kind == "member"))
                && accept("bind")) then {
                var dest := values.pop
                if (dest.kind == "lbrace") then {
                    print "sym = {sym}, sym.line = {sym.line}"
                    ProgrammingError.raise "popped lbrace token while parsing statement"
                }
                next
                if (didNotConsume {expression(blocksOK)}) then {
                    reportBadRhs
                }
                var val := values.pop
                util.setPosition(btok.line, btok.linePos)
                var o := ast.bindNode.new(dest, val)
                values.push(o)
            }
        }
    }
    reconcileComments
    if (accept "eof") then {
        return true
    }
}

method pushComments {
    // Push a comment onto the comments stack as a commentNode. If
    // there are consecutive comments following, deal with them all.
    // Adjacent comments extend the first; a break of a blank line
    // starts a new comment node.

    if ( ! accept "comment" ) then { return }
    util.setPosition(sym.line, sym.linePos)
    var o := ast.commentNode.new(sym.value)
    if ((lastToken.line == sym.line) && (lastToken.kind != "comment")) then {
        o.isPartialLine := true
    } elseif { lastToken.line < (sym.line - 1) } then {
        o.isPreceededByBlankLine := true
    }
    comments.push(o)
    while { 
        previousCommentToken := sym
        sym := tokens.poll
        accept "comment"
    } do {
        util.setPosition(sym.line, sym.linePos)
        o := ast.commentNode.new(sym.value)
        if ( comments.last.endLine == (sym.line - 1) ) then {
            comments.last.extendCommentUsing(o)
        } else {
            comments.push(o)
            if ( lastToken.line < (sym.line - 1) ) then {
                o.isPreceededByBlankLine := true
            }
        }
    }
}

method reconcileComments {
    // Should be requested after a new node that represents a "syntactic unit"
    // to which comments can be attached is pushed onto `values`
    // Finds comments associated with that node, removes them from comments
    // stack, and puts them in that node's comments attribute.

    pushComments
    def node = if (values.isEmpty) then {
        moduleObject 
    } else {
        values.last
    }
    if (node.kind == "lbrace") then {
        // lbrace nodes are not AST nodes.  They are used to mark the stack for
        // nested expressions.  Hence, no comments should be attached to them.
        return
    }
    def oLine = node.line
    def preComments = emptyList
    def postComments = emptyList

    var ix := comments.size
    while { ix > 0 } do {
        def each = comments.at(ix)
        def isPostComment = (each.line == oLine) || (each.line == (oLine+1))
        def isPreComment = each.isPreceededByBlankLine && (each.endLine == (oLine-1))
        if (isPostComment) then {
            postComments.push(comments.removeAt(ix))
        } elseif { isPreComment } then {
            preComments.addFirst(comments.removeAt(ix))
        } elseif { each.endLine < (oLine-1) } then {
            ix := 0     // exit from while
        }
        ix := ix - 1
    }

    def postSz = postComments.size
    def preSz = preComments.size

    if ((postSz > 1) && (preSz > 1)) then {
        preComments.last.value := preComments.last.value ++ "\n"
    }
    node.addComments(preComments)
    node.addComments(postComments)
}

method checkBadOperators {
    if (sym.value == "=") then {
        def sugg = errormessages.suggestion.new
        sugg.insert("=")afterToken(sym)
        errormessages.syntaxError("use '==' to test equality, not '='.")
            atRange(sym.line, sym.linePos, sym.linePos)
            withSuggestion(sugg)
    }
}

method checkBadTypeLiteral {
    if (sym.kind == "lbrace") then {
        def sugg = errormessages.suggestion.new
        sugg.insert("type ") beforeToken(sym)
        errormessages.syntaxError("type literals must start with the keyword 'type'.")
            atRange(sym.line, sym.linePos, sym.linePos)
            withSuggestion(sugg)
    }
}

method checkUnexpectedTokenAfterStatement {
    if (sym.line == lastToken.line) then {
        if ((sym.kind == "op") && (sym.value == "=")
            && (lastToken.kind == "identifier")) then {
            def sugg = errormessages.suggestion.new
            def suggestions = [ ]
            sugg.replaceToken(sym)leading(false)trailing(false)with(":=")
            suggestions.push(sugg)
            def sugg2 = errormessages.suggestion.new
            sugg2.replaceToken(sym)leading(false)trailing(false)with "=="
            suggestions.push(sugg2)
            errormessages.syntaxError("assignment uses ':=', not '='.")
                atRange(sym.line, sym.linePos, sym.linePos)
                withSuggestions (suggestions)
        }
        if (sym.kind != "rbrace") then {
            def suggestions = [ ]
            var suggestion
            if ( (values.size > 0) && { (values.last.kind == "identifier") || { values.last.kind == "member" }} && { sym.kind == "identifier" } ) then {
                suggestion := errormessages.suggestion.new
                suggestion.replaceToken(sym)leading(true)trailing(false)with("({sym.value})")
                suggestions.push(suggestion)
                if (false != sym.next) then {
                    def n = sym.next
                    if (n.line == sym.line) then {
                        suggestion := errormessages.suggestion.new
                        suggestion.replaceToken(sym)leading(true)trailing(false)with("({sym.value}")
                        suggestion.append ")" onLine(sym.line)
                        suggestions.push(suggestion)
                    }
                }
                if (values.last.kind == "identifier") then {
                    suggestion := errormessages.suggestion.new
                    suggestion.replaceToken(sym)leading(false)trailing(false)with("\"{sym.value}\"")
                    suggestions.push(suggestion)
                }
            }
            def nextTok = findNextValidToken( ["rbrace"] )
            if (nextTok == sym) then {
                suggestion := errormessages.suggestion.new
                suggestion.addLine(lastToken.line, util.lines.at(lastToken.line).substringFrom(1)to(lastToken.endPos))
                def newLine = util.lines.at(sym.line).substringFrom(sym.linePos)to(util.lines.at(sym.line).size)
                suggestion.addLine(lastToken.line + 0.1, newLine)
                suggestions.push(suggestion)
            } else {
                suggestion := errormessages.suggestion.new
                suggestion.deleteTokenRange(sym, nextTok.prev)leading(true)trailing(false)
                suggestions.push(suggestion)
            }
            errormessages.syntaxError(
                "multiple statements must be separated by a newline or a semicolon. " ++
                  "This error is often caused by unbalanced parentheses, " ++
                    "or by omitting a part of a method name.\nsym = {sym}")
                      atPosition (sym.line, sym.linePos) withSuggestions (suggestions)
        }
    }
}


method parse(toks) {
    // Parses toks, a linked list of tokens, and returns an AST moduleNode
    // corresponding to it.

    util.log_verbose "parsing."
    moduleObject := ast.moduleNode.body(values) named (util.modname)

    if (toks.size == 0) then {
        return moduleObject
    }
    tokens := toks
    while { next ; acceptSeparator } do { }

    if (sym.indent > 0) then {
        def sugg = errormessages.suggestion.new
        sugg.deleteRange(1, sym.indent) onLine(sym.line)
        errormessages.syntaxError "the first line must not be indented."
            atRange(sym.line, 1, sym.indent)
            withSuggestion(sugg)
    }
    var oldlength := tokens.size
    while {tokens.size > 0} do {
        pushComments
        methoddec
        pushComments
        if (didConsume { inheritOrUse }) then {
            def parentNode = values.pop
            if (parentNode.isUse) then {
                moduleObject.usedTraits.add(parentNode)
            } elseif { moduleObject.usedTraits.isEmpty } then {
                moduleObject.superclass := parentNode
            } else {
                errormessages.syntaxError("'inherit' must come " ++
                    "before 'use' in a module.")
                    atRange(parentNode.line, parentNode.linePos,
                    parentNode.linePos + 6)
            }
        }
        statement
        pushComments
        if (tokens.size == oldlength) then {
            def suggestion = errormessages.suggestion.new
            suggestion.deleteToken(sym)
            errormessages.syntaxError ("invalid statement. This is often " ++
                "caused by an extra '}', ')', or ']'.")
                atRange (sym.line, sym.linePos, sym.endPos)
                withSuggestion (suggestion)
        }
        oldlength := tokens.size
    }
    statement
    pushComments
    return moduleObject
}
