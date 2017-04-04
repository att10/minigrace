#pragma ExtendedLineups
import "io" as io
import "sys" as sys
import "util" as util
import "ast" as ast
import "mirrors" as mirrors
import "errormessages" as errormessages
import "unixFilePath" as filePath


def CheckerFailure = Exception.refine "CheckerFailure"
def DialectError is public = prelude.Exception.refine "DialectError"
    //must correspond to what is defined in "dialect"

def gctCache = emptyDictionary
def keyCompare = { a, b -> a.key.compare(b.key) }

def builtInModules =
        list [  "imports",
                "io",
                "mirrors",
                "sys",
                "unicode",
                "util" ]

def currentDialect is public = object {
    var name is public := "standardGrace"
    var moduleObject is public := prelude
    // TODO: this isn't quite right: should be the prelude
    // on the GRACE_MODULE_PATH of this compilation
    var hasParseChecker is public := false
    var hasAstChecker is public := false
    var hasAtStart is public := false
    var hasAtEnd is public := false
}

type LinePos = {
    line -> Number
    linePos -> Number
}

type RangeSuggestions = {
    line -> Number
    posStart -> Number
    posEnd -> Number
    suggestions
}

def dynamicCModules is public = set ["mirrors", "curl", "unicode"]
def imports = util.requiredModules

method checkDialect(moduleObject) {
    def dialectNode = moduleObject.theDialect
    def dmn = dialectNode.moduleName
    currentDialect.name := dmn
    if (dmn == "none") then { return }
    util.log 50 verbose "checking dialect {dmn} used by module {moduleObject.name}"
    checkExternalModule(dialectNode)
    def dialectGct = parseGCT(dialectNode.value)
    if ((dialectGct.at "public" ifAbsent {emptySequence}).contains "thisDialect") then {
        util.log 50 verbose "loading dialect \"{dmn}\" for checkers."
        try {
            def dobj = mirrors.loadDynamicModule(dialectNode.path)
            currentDialect.moduleObject := dobj
            if (mirrors.reflect(dobj).methodNames.contains "thisDialect") then {
                def mths = mirrors.reflect(dobj.thisDialect).methods
                for (mths) do { m ->
                    if (m.name == "parseChecker(_)") then {
                        currentDialect.hasParseChecker := true
                    }
                    if (m.name == "astChecker(_)") then {
                        currentDialect.hasAstChecker := true
                    }
                    if (m.name == "atEnd(_)") then {
                        currentDialect.hasAtEnd := true
                    }
                    if (m.name == "atStart(_)") then {
                        currentDialect.hasAtStart := true
                    }
                }
            }
        } catch { e:Exception ->
            util.setPosition(dialectNode.line, 1)
            e.printBacktrace
            errormessages.error "Dialect error: dialect \"{dmn}\" failed to load.\n{e}."
                atLine(dialectNode.line)
        }
    } else {
        util.log 50 verbose "no need to load dialect \"{dmn}\": it does not define `thisDialect`"
    }
}

method doParseCheck(moduleNode) {
    if (currentDialect.hasParseChecker.not) then { return }
    try {
        currentDialect.moduleObject.thisDialect.parseChecker(moduleNode)
    } catch { e:CheckerFailure | DialectError ->
        reportDialectError(e)
    } catch { e:Exception ->      // some unknown Grace exception
        printBacktrace (e) asFarAs "thisDialect.parseChecker"
        errormessages.error("Unexpected exception raised by parse checker for " ++
            "dialect '{currentDialect.name}'.\n{e.exception}: {e.message}")
    }
}

method doAstCheck(moduleNode) {
    if (currentDialect.hasAstChecker.not) then { return }
    try {
        currentDialect.moduleObject.thisDialect.astChecker(moduleNode)
    } catch { e:CheckerFailure | DialectError ->
        reportDialectError(e)
    } catch { e:Exception ->      // some unknown Grace exception
        printBacktrace (e) asFarAs "thisDialect.astChecker"
        errormessages.error("Unexpected exception raised by AST checker for " ++
            "dialect '{currentDialect.name}'.\n{e.exception}: {e.message}")
    }
}

method reportDialectError(ex) {
    match (ex.data)
        case { rs:RangeSuggestions ->
            errormessages.error "Dialect {currentDialect.name}: {ex.message}."
                atRange(rs)
                withSuggestions(rs.suggestions)
        }
        case { r:ast.Range ->  //  inlcudes ast.AstNode
            errormessages.error "Dialect {currentDialect.name}: {ex.message}."
                atRange(r)
        }
        case { p:ast.Position ->
            errormessages.error "Dialect {currentDialect.name}: {ex.message}."
                atPosition(p.line, p.column)
        }
        case { _ ->
            errormessages.error "Dialect {currentDialect.name}: {ex.message}."
                atLine(util.linenum)
        }
}

method printBacktrace(exceptionPacket) asFarAs (methodName) {
    def ex = exceptionPacket.exception
    def msg = exceptionPacket.message
    def lineNr = exceptionPacket.lineNumber
    def mod = exceptionPacket.moduleName
    io.error.write "{ex} on line {lineNr} of {mod}: {msg}\n"
    def bt = exceptionPacket.backtrace
    while {bt.size > 0} do {
        def frameDescription = bt.pop
        io.error.write "  requested from {frameDescription}\n"
        if (frameDescription.contains(methodName)) then { return }
    }
}

method checkExternalModule(node) {
    checkimport(node.moduleName, node.path, node.isDialect, node.range)
}

method checkimport(nm, pathname, isDialect, sourceRange) is confidential {
    if (builtInModules.contains(nm)) then {
        imports.other.add(nm)
        return
    }
    if (imports.isAlready(nm)) then {
        return
    }

    if (prelude.inBrowser) then {
        util.file(nm ++ ".js") onPath "" otherwise { _ ->
            errormessages.error "Please compile module {nm} before importing it."
                atRange(sourceRange)
        }
        return
    }
    def gmp = sys.environ.at "GRACE_MODULE_PATH"
    def pn = filePath.fromString(pathname).setExtension "gct"
    def moduleFileGct = util.file(pn) on (util.outDir)
                                orPath (gmp) otherwise { l ->
        def graceFile = pn.copy.setExtension "grace"
        def moduleFileGrace = util.file(graceFile) on(util.outDir)
                                orPath (gmp) otherwise { m ->
            def rm = errormessages.readableStringFrom(m)
            errormessages.error("I can't find {pn.shortName} " ++
                "or {graceFile.shortName}; looked in {rm}.") atRange (sourceRange)
        }
        compileModule (nm) inFile (moduleFileGrace.asString)
                forDialect (isDialect) atRange (sourceRange)
        util.file(pn) on(util.outDir) orPath (gmp) otherwise { m ->
            def rm = errormessages.readableStringFrom(m)
            errormessages.error("I just compiled {moduleFileGrace} " ++
                "but can't find the .gct; looked in {rm}.") atRange (sourceRange)
        }
    }

    def gctDict = gctCache.at(nm) ifAbsent {
        parseGCT (nm) sourceDir (moduleFileGct.directory)
    }
    def sourceFile = filePath.fromString(gctDict.at "path" .first)
    def sourceExists = if (sourceFile.directory.contains "stub") then {
        false        // for binary-only modules like unicode
    } else {
        sourceFile.exists
    }
    if ( util.target == "js" ) then {
        def moduleFileJs = moduleFileGct.copy.setExtension ".js"
        if (moduleFileJs.exists && {
            moduleFileGct.exists } && {
                sourceExists.not || { moduleFileJs.newer(sourceFile) }
            }
        ) then {
        } else {
            if (moduleFileJs.newer(sourceFile).not) then {
                util.log 60 verbose "{moduleFileJs} not newer than {sourceFile}"
            }
            if (sourceFile.exists) then {
                compileModule (nm) inFile (sourceFile.asString)
                    forDialect (isDialect) atRange (sourceRange)
            } else {
                def thing = if (isDialect) then {"dialect"} else {"module"}
                errormessages.error "Can't find {thing} {nm}"
                    atRange(sourceRange)
            }
        }
        imports.other.add(nm)
    }
    addTransitiveImports(moduleFileGct.directory, isDialect, nm, sourceRange)
}

method directory (d) expectedOrInPath (p) -> Boolean {
    // is directory d one of the expected directories, or in the path string p
    // The expected directories are the directory where the compiler lives, the
    // directory where the input lives, and the current directory.
    // All comparisons are between absolute path names.

    def dr = io.realpath(d)
    if (dr == io.realpath "./") then { return true }
    if (dr == io.realpath(util.sourceDir)) then { return true }
    if (dr == io.realpath(sys.execPath)) then { return true }
    filePath.split(p).do { d1 ->
        if (dr == io.realpath(d1)) then { return true }
    }
    def pathdirs = filePath.split(p).map { each -> io.realpath(each) }
    util.log 50 verbose("directory(_)expectedOrInPath(_) returning false.\n " ++
        "Looking for {dr}\nTried ./ = {io.realpath "./"}\n" ++
        "    sourceDir = {io.realpath(util.sourceDir)}\n" ++
        "    execDir = {io.realpath(sys.execPath)}\n" ++
        "    PATH dirs = {pathdirs}\n")
    return false
}
method addTransitiveImports(directory, isDialect, moduleName, sourceRange) is confidential {
    util.log 50 verbose "adding transitive imports for {moduleName}"
    def gctData = gctCache.at(moduleName) ifAbsent {
        parseGCT(moduleName) sourceDir(directory)
    }
    if (gctData.containsKey "dialect") then {
        def dialects = gctData.at "dialect"
        if (dialects.isEmpty.not) then {
            def dName = gctData.at "dialect" .first
            checkimport(dName, dName, true, sourceRange)
        }
    }
    def importedModules = gctData.at "modules" ifAbsent { emptySequence }
    def m = util.modname
    if (importedModules.contains(m)) then {
        errormessages.error("Cyclic import detected: '{m}' is imported "
            ++ "by '{moduleName}', which is imported by '{m}' (and so on).")
            atRange(sourceRange)
    }
    importedModules.do { each ->
        checkimport(each, each, isDialect, sourceRange)
    }
}

method compileModule (nm) inFile (sourceFile)
        forDialect (isDialect) atRange (sourceRange) is confidential {
    if ( prelude.inBrowser || { util.recurse.not } ) then {
        errormessages.error "Please compile module {nm} before using it."
            atRange (sourceRange)
    }
    var slashed := false
    for (sys.argv.first) do {letter ->
        if(letter == "/") then {
            slashed := true
        }
    }
    var cmd
    if (slashed) then {
        cmd := io.realpath(sys.argv.first)
    } else {
        cmd := io.realpath "{sys.execPath}/{sys.argv.first}"
    }
    def cmdSz = cmd.size
    if (cmd.substringFrom(cmdSz-2) to (cmdSz) == ".js") then {
        cmd := "grace \"{cmd}\""
    } else {
        cmd := "\"{cmd}\""
    }
    if (util.verbosity != util.defaultVerbosity) then {
        cmd := cmd ++ " --verbose {util.verbosity}"
    }
    if (util.dirFlag) then {
        cmd := cmd ++ " --dir " ++ util.outDir
    }
    if (false != util.vtag) then {
        cmd := cmd ++ " --vtag " ++ util.vtag
    }
    cmd := cmd ++ " --gracelib " ++ util.gracelibPath
    cmd := cmd ++ util.commandLineExtensions
    cmd := "{cmd} --target {util.target} --noexec \"{sourceFile}\""
    util.log 50 verbose "executing sub-compile {cmd}"
    def exitCode = io.spawn("bash", ["-c", cmd]).status
    if (exitCode != 0) then {
        errormessages.error "Failed to compile imported module {nm} ({exitCode})."
            atRange (sourceRange)
    }
}

method parseGCT(moduleName) {
    gctCache.at(moduleName) ifAbsent {
        parseGCT(moduleName) sourceDir(util.outDir)
    }
}

method parseGCT(moduleName) sourceDir(dir) is confidential {
    def gctData = emptyDictionary
    def sz = moduleName.size
    def sought = filePath.fromString(moduleName).setExtension ".gct"
    def filename = util.file(sought) on(dir)
      orPath(sys.environ.at "GRACE_MODULE_PATH") otherwise { l ->
        def rl = errormessages.readableStringFrom(l)
        util.log 80 verbose "Can't find file {sought} for module {moduleName}; looked in {rl}."
        gctCache.at(moduleName) put(gctData)
        return gctData
    }
    def tfp = io.open(filename, "r")
    var key := ""
    while {!tfp.eof} do {
        def line = tfp.getline
        if (line.size > 0) then {
            if (line.at(1) != " ") then {
                key := line.substringFrom 1 to (line.size-1)
                gctData.at(key) put [ ]
            } else {
                gctData.at(key).addLast(line.substringFrom 2 to (line.size))
            }
        }
    }
    tfp.close
    gctCache.at(moduleName) put(gctData)
    return gctData
}

method writeGCT(modname, dict) is confidential {
    def fp = io.open("{util.outDir}{modname}.gct", "w")
    list(dict.bindings).sortBy(keyCompare).do { b ->
        fp.write "{b.key}:\n"
        list(b.value).sort.do { v ->
            fp.write " {v}\n"
        }
    }
    fp.close
    gctCache.at(modname) put(dict)
}

method writeGctForModule(moduleObject) {
    writeGCT(moduleObject.name, generateGctForModule(moduleObject))
}

method gctAsString(gctDict) {
    var ret := ""
    list(gctDict.bindings).sortBy(keyCompare).do { b ->
        ret := ret ++ "{b.key}:\n"
        list(b.value).sort.do { v ->
            ret := ret ++ " {v}\n"
        }
    }
    return ret
}

var methodtypes := [ ]
def typeVisitor = object {
    inherit ast.baseVisitor
    var literalCount := 1
    method visitTypeLiteral(lit) {
        for (lit.methods) do { meth ->
            var mtstr := "{literalCount} "
            for (meth.signature) do { part ->
                mtstr := mtstr ++ part.name
                if (part.params.size > 0) then {
                    mtstr := mtstr ++ "("
                    for (part.params.indices) do { pnr ->
                        var p := part.params.at(pnr)
                        if (p.dtype != false) then {
                            mtstr := mtstr ++ p.toGrace(1)
                        } else {
                            // if parameter type not listed, give it type Unknown
                            if(p.wildcard) then {
                                mtstr := mtstr ++ "_"
                            } else {
                                mtstr := mtstr ++ p.value
                            }
                            mtstr := mtstr ++ ":" ++ ast.unknownType.value
                            if (false != p.generics) then {
                                mtstr := mtstr ++ "⟦"
                                for (1..(p.generics.size - 1)) do {ix ->
                                    mtstr := mtstr ++ p.generics.at(ix).toGrace(1) ++ ", "
                                }
                                mtstr := mtstr ++ p.generics.last.toGrace(1) ++ "⟧"
                            }
                        }
                        if (pnr < part.params.size) then {
                            mtstr := mtstr ++ ", "
                        }
                    }
                    mtstr := mtstr ++ ")"
                }
            }
            if (meth.rtype != false) then {
                mtstr := mtstr ++ " → " ++ meth.rtype.toGrace(1)
            }
            methodtypes.push(mtstr)
        }
        return false
    }
    method visitOp(op) {
        if ((op.value=="&") || (op.value=="|")) then {
            def leftkind = op.left.kind
            def rightkind = op.right.kind
            if ((leftkind=="identifier") || (leftkind=="member")) then {
                var typeIdent := op.left.toGrace(0)
                methodtypes.push("{op.value} {typeIdent}")
            } elseif { leftkind=="typeliteral" } then {
                literalCount := literalCount + 1
                methodtypes.push("{op.value} {literalCount}")
                visitTypeLiteral(op.left)
            } elseif { leftkind=="op" } then {
                visitOp(op.left)
            }
            if ((rightkind=="identifier") || (rightkind=="member")) then {
                var typeIdent := op.right.toGrace(0)
                methodtypes.push("{op.value} {typeIdent}")
            } elseif { rightkind=="typeliteral" } then {
                literalCount := literalCount + 1
                methodtypes.push("{op.value} {literalCount}")
                visitTypeLiteral(op.right)
            } elseif { rightkind=="op" } then {
                visitOp(op.right)
            }
        }
        return false
    }
}
method generateGctForModule(moduleObject) is confidential {
    def gct = buildGctFor(moduleObject)
    addFreshMethodsOf (moduleObject) to (gct)
    return gct
}

method buildGctFor(module) {
    def gct = emptyDictionary
    def classes = emptyList
    def confidentials = emptyList
    def meths = emptyList
    def types = emptyList
    def theDialect = module.theDialect.moduleName
    module.parentsDo { p ->
        meths.addAll(p.providedNames)
    }
    for (module.value) do { v->
        if (v.kind == "vardec") then {
            if (v.isReadable) then {
                meths.push(v.name.value)
            }
            if (v.isWritable) then {
                meths.push(v.name.value ++ ":=(1)")
            }
        } elseif {v.kind == "method"} then {
            if (v.isPublic) then {
                meths.push(v.nameString)
            } else {
                confidentials.push(v.nameString)
            }
        } elseif {v.kind == "typedec"} then {
            if (v.isPublic) then {
                meths.push(v.nameString)
                types.push(v.name.value)
                methodtypes := [ ]
                v.accept(typeVisitor)
                var typename := v.name.toGrace(0)
                if (v.typeParams != false) then {
                    typename := typename ++ v.typeParams
                }
                gct.at "methodtypes-of:{typename}" put(methodtypes)
            } else {
                confidentials.push(v.nameString)
            }
        } elseif {v.kind == "defdec"} then {
            if (v.isPublic) then {
                meths.push(v.nameString)
            } else {
                confidentials.push(v.nameString)
            }
            if (ast.findAnnotation(v, "parent")) then {
                v.scope.elements.keysDo { m -> meths.push(m) }
            }
            if (v.returnsObject) then {
                def ob = v.returnedObjectScope.node
                def obConstructors = [ ]
                if (ob.isObject) then {
                  for (ob.value) do {nd->
                    if (nd.isClass) then {
                        def factMethNm = nd.nameString
                        obConstructors.push(factMethNm)
                        def exportedMethods = emptyList
                        ob.scope.getScope(factMethNm).keysAndKindsDo { key, knd ->
                            if (knd.forGct) then { exportedMethods.add(key) }
                        }
                        gct.at "methods-of:{v.name.value}.{factMethNm}"
                            put(exportedMethods.sort)
                    }
                  }
                }
                if (obConstructors.size > 0) then {
                    gct.at "constructors-of:{v.name.value}"
                        put(obConstructors)
                    classes.push(v.name.value)
                }
            }
        }
    }
    gct.at "classes" put(classes.sort)
    gct.at "confidential" put(confidentials.sort)
    gct.at "modules" put(list(module.imports).sorted)
    gct.at "path" put [
        if (util.infile.pathname.isEmpty) then { "" }
            else { io.realpath(util.infile.pathname) }
    ]
    gct.at "public" put(meths.sort)
    gct.at "types" put(types.sort)
    gct.at "dialect" put (
        if (theDialect == "none") then { [] } else { [theDialect] }
    )
    gct
}

method addFreshMethodsOf (moduleObject) to (gct) is confidential {
    // adds information about the methods made available via fresh methods.
    // This is done in a separate pass after public information is in the gct,
    // because of the special treatment of intrinsic.clone
    // TODO: doesn't this just duplicate what's in 'classes' ? No: 'classes'
    // lists only classes declared inside a def'd object constructor, i.e.,
    // something simulating he old "dotted" class
    def freshmeths = [ ]
    for (moduleObject.value) do { node->
        if (node.isClass) then {
            addFreshMethod (node) to (freshmeths) for (gct)
        }
    }
    gct.at "fresh-methods" put(freshmeths)
}

method addFreshMethod (node) to (freshlist) for (gct) is confidential {
    def methName = node.nameString
    freshlist.push(methName)
    def freshMethExpression = node.body.last
    if (freshMethExpression.isObject) then {
        def exportedMethods = emptyList
        freshMethExpression.scope.keysAndKindsDo { key, knd ->
            if (knd.forGct) then { exportedMethods.add(key) }
        }
        gct.at "fresh:{methName}" put (exportedMethods.sort)
    } elseif {freshMethExpression.isCall} then {
        // this deals with the two special cases, defined in
        // ast.callNode.returnsObject.  The freshMethExpression must
        // be a request of self.copy or intrinsic.clone(_)
        def requestedName = freshMethExpression.nameString
        if (requestedName == "copy") then {
            gct.at "fresh:{methName}" put(gct.at "public")
        } elseif {requestedName == "clone(1)"} then {
            def cloneArg = freshMethExpression.parts.first.args.first
            if (cloneArg.isSelf) then {
                gct.at "fresh:{methName}" put(gct.at "public")
            } else {
                gct.at "fresh:{methName}"
                    put(gct.at "methods-of:{cloneArg.toGrace 0}" isAbsent {
                        ProgrammingError.raise (
                            "unrecognized fresh method tail-call:\n" ++
                              freshMethExpression.pretty(0) ++ "\n" ++
                                "Can't find methods-of:{cloneArg.toGrace 0} in gct." )
                    } )
            }
        } else {
            // if it's not a call or an object constructor, why is it labelled as fresh?
            ProgrammingError.raise
                "unrecognized fresh method tail-call: {freshMethExpression.pretty(0)}"
        }
    } else {
        ProgrammingError.raise
            "fresh method result of an unexpected kind: {freshMethExpression.pretty(0)}"
    }
}
