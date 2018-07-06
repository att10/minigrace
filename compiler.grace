import "ast" as ast
import "buildinfo" as buildinfo
import "genjs" as genjs
import "identifierresolution" as identifierresolution
import "io" as io
import "lexer" as lexer
import "mirrors" as mirrors
import "parser" as parser
import "sys" as sys
import "unicode" as unicode
import "util" as util
import "xmodule" as xmodule

util.parseargs(buildinfo)

util.log_verbose "starting compilation"

var tokens := lexer.new.lexfile(util.infile)
if (util.target == "lex") then {
    // Print the lexed tokens and quit.
    for (tokens) do { v ->
        def val = if ("\n" == v.value) then { "\\n" } else { v.value }
        if (util.verbosity > 30) then {
            util.outprint "{v.kind}: {val}  [pos: {v.line}.{v.linePos} size: {v.size} indent: {v.indent}]"
        } else {
            util.outprint "{v.kind}: {val}"
        }
    }
    util.outfile.close
    sys.exit(0)
}

var moduleObject := parser.parse(tokens)

if (util.extensions.contains "NativePrelude") then {
    moduleObject.theDialect := ast.dialectNode.new "none"
    // for backward compatibility
}

var values := moduleObject.value

if (util.target == "parse") then {
    // Parse mode pretty-prints the parse tree and quits.
//    util.log 60 verbose "target = parse, outfile = {util.outfile}."
    util.outprint(moduleObject.pretty(0))
//    util.log 60 verbose "done writing {util.outfile}."
    util.outfile.close
    sys.exit(0)
}
if (util.target == "grace") then {
    for (values) do { v ->
        util.outprint(v.toGrace(0))
    }
    util.outfile.close
    sys.exit(0)
}

xmodule.checkDialect(moduleObject)
xmodule.doParseCheck(moduleObject)

if (util.extensions.contains("Plugin")) then {
    mirrors.loadDynamicModule(util.extensions.get("Plugin")).processAST(values)
}
if (util.target == "imports") then {
    def imps = emptySet
    def vis = object {
        inherit ast.baseVisitor
        method visitImport(o) -> Boolean {
            imps.add(o.path)
            false
        }
    }
    moduleObject.accept(vis)

    list(imps).sort.do { im ->
        util.outprint(im)
    }
    util.outfile.close
    sys.exit(0)
}
moduleObject := identifierresolution.resolve(moduleObject)
if ((util.target == "processed-ast") || (util.target == "ast")) then {
    util.outprint "====================================="
    util.outprint "module-level symbol table"
    util.outprint (moduleObject.scope.asStringWithParents)
    util.outprint "====================================="
    util.outprint(moduleObject.pretty(0))
    util.outfile.close
    sys.exit(0)
}

xmodule.doAstCheck(moduleObject)

// Perform the actual compilation
match(util.target)
  case { "js" ->
    genjs.compile(moduleObject, util.outfile, util.buildtype, util.gracelibPath)
} case { _ ->
    io.error.write("minigrace: no such target '" ++ util.target ++ "'\n")
    sys.exit(1)
}
