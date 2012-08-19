#pragma DefaultVisibility=public
import io
import sys
import buildinfo

var __compilerRevision := false
var verbosityv := 30
var outfilev := io.output
var infilev := io.input
var modnamev := "stdin_minigrace"
var runmodev := "make"
var buildtypev := "run"
var gracelibPathv := false
var linenumv := 1
var lineposv := 1
var vtagv := false
var noexecv := false
var targetv := "c"
var versionNumber := "0.0.7"
var extensionsv := HashMap.new
var recurse := true
var dynamicModule := false
var importDynamic := false
var jobs := 2
var cLines := []
var lines := []

method runOnNew(b)else(e) {
    if ((__compilerRevision != "672d7488e743e6714989f56a577f31a70c0f6e5e")
        && (__compilerRevision != false)) then {
        b.apply
    } else {
        e.apply
    }
}

method parseargs {
    var argv := sys.argv
    var toStdout := false
    if (argv.size > 1) then {
        var indices := argv.indices
        var arg
        var skip := true
        for (indices) do { ai->
            arg := argv.at(ai)
            if (arg.at(1) == "-") then {
                match(arg)
                    case { "-o" ->
                        outfilev := io.open(argv.at(ai + 1), "w")
                        skip := true
                    } case { "--verbose" ->
                        verbosityv := 40
                    } case { "--vtag" ->
                        skip := true
                        vtagv := argv.at(ai + 1)
                    } case { "--make" ->
                        runmodev := "make"
                        buildtypev := "bc"
                    } case { "--no-recurse" ->
                        recurse := false
                    } case { "--dynamic-module" ->
                        dynamicModule := true
                        runmodev := "make"
                        noexecv := true
                        buildtypev := "bc"
                    } case { "--import-dynamic" ->
                        importDynamic := true
                    } case { "--run" ->
                        buildtypev := "run"
                        runmodev := "make"
                    } case { "--source" ->
                        buildtypev := "source"
                        runmodev := "build"
                    } case { "--native" ->
                        buildtypev := "native"
                    } case { "--noexec" ->
                        noexecv := true
                    } case { "--yesexec" ->
                        noexecv := false
                    } case { "--stdout" ->
                        toStdout := true
                    } case { "-" ->
                        toStdout := true
                    } case { "--module" ->
                        skip := true
                        modnamev := argv.at(ai + 1)
                    } case { "--gracelib" ->
                        skip := true
                        gracelibPathv := argv.at(ai + 1)
                    } case { "--target" ->
                        skip := true
                        targetv := argv.at(ai + 1)
                    } case { "-j" ->
                        skip := true
                        jobs := argv.at(ai + 1).asNumber
                    } case { "--version" ->
                        print("minigrace "
                            ++ "{versionNumber}.{buildinfo.gitgeneration}")
                        print("git revision " ++ buildinfo.gitrevision)
                        print("<http://ecs.vuw.ac.nz/~mwh/minigrace/>")
                        sys.exit(0)
                    } case { "--help" ->
                        print "Usage: minigrace <file>.grace"
                        print "See the documentation for more options."
                        sys.exit(0)
                    } case { _ ->
                        if (arg.at(2) == "X") then {
                            var ext := arg.substringFrom(3)to(arg.size)
                            processExtension(ext)
                        } else {
                            io.error.write("minigrace: invalid "
                                ++ "argument {arg}.\n")
                            sys.exit(1)
                        }
                    }
            } else {
                if (skip) then {
                    skip := false
                } else {
                    var filename := arg
                    infilev := io.open(filename, "r")
                    if (modnamev == "stdin_minigrace") then {
                        var accum := ""
                        modnamev := ""
                        for (filename) do { c->
                            if (c == ".") then {
                                modnamev := accum
                            }
                            accum := accum ++ c
                        }
                    }
                }
            }
        }
    }
    if ((outfilev == io.output) && {!toStdout}) then {
        outfilev := match(targetv)
            case { "c" -> io.open(modnamev ++ ".c", "w") }
            case { "js" -> io.open(modnamev ++ ".js", "w") }
            case { _ -> io.output }
    }
    if (gracelibPathv == false) then {
        if (io.exists(sys.execPath ++ "/../lib/minigrace/gracelib.o")) then {
            gracelibPathv := sys.execPath ++ "/../lib/minigrace"
        } else {
            gracelibPathv := sys.execPath
        }
    }
    if (infilev == io.input) then {
        if (infilev.isatty) then {
            print("minigrace {versionNumber}.{buildinfo.gitgeneration} / "
                ++ buildinfo.gitrevision)
            print "Copyright (C) 2011, 2012 Michael Homer"
            print("This is free software with ABSOLUTELY NO WARRANTY. "
                ++ "Say minigrace.w for details.")
            print ""
            print "Enter a program and press Ctrl-D to execute it."
            print ""
        }
    }
}

method log_verbose(s) {
    if (verbosityv >= 40) then {
        var vtagw := ""
        if (false != vtagv) then {
            vtagw := "[" ++ vtagv ++ "]"
        }
        io.error.write("minigrace{vtagw}: {modnamev}: {sys.cputime}/"
            ++ "{sys.elapsed}: {s}\n")
    }
}

method outprint(s) {
    outfilev.write(s)
    outfilev.write("\n")
}
method syntax_error(s) {
    if (vtagv) then {
        io.error.write("[" ++ vtagv ++ "]")
    }
    io.error.write("{modnamev}.grace:{linenumv}:{lineposv}: Syntax error: {s}")
    io.error.write("\n")
    if (linenumv > 1) then {
        io.error.write("  {linenumv - 1}: {lines.at(linenumv - 1)}\n")
    }
    var arr := "----"
    for (2..(lineposv + linenumv.asString.size)) do {
        arr := arr ++ "-"
    }
    if (lines.size >= linenumv) then {
        io.error.write("  {linenumv}: {lines.at(linenumv)}\n{arr}^\n")
    }
    if (linenumv < lines.size) then {
        io.error.write("  {linenumv + 1}: {lines.at(linenumv + 1)}\n")
    }
    sys.exit(1)
}
method type_error(s) {
    if (extensionsv.contains("IgnoreTypes")) then {
        return true
    }
    if (vtagv) then {
        io.error.write("[" ++ vtagv ++ "]")
    }
    io.error.write("{modnamev}.grace:{linenumv}:{lineposv}: Type error: {s}")
    io.error.write("\n")
    io.error.write(lines.at(linenumv) ++ "\n")
    sys.exit(1)
}
method warning(s) {
    io.error.write("{modnamev}.grace:{linenumv}:{lineposv}: warning: {s}")
    io.error.write("\n")
}

method verbosity {
    verbosityv
}
method outfile {
    outfilev
}
method infile {
    infilev
}
method modname {
    modnamev
}
method runmode {
    runmodev
}
method buildtype {
    buildtypev
}
method gracelibPath {
    gracelibPathv
}
method setline(l) {
    linenumv := l
}
method setPosition(l, p) {
    linenumv := l
    lineposv := p
}
method linenum {
    linenumv
}
method linepos {
    lineposv
}
method vtag {
    vtagv
}
method noexec {
    noexecv
}
method target {
    targetv
}
method engine {
    "native"
}
method extensions {
    extensionsv
}
method processExtension(ext) {
    var extn := ""
    var extv := true
    var seeneq := false
    for (ext) do {c->
        if (c == "=") then {
            seeneq := true
            extv := ""
        } else {
            if (!seeneq) then {
                extn := extn ++ c
            } else {
                extv := extv ++ c
            }
        }
    }
    extensionsv.put(extn, extv)
}
method debug(s) {

}
var hexdigits := "0123456789abcdef"
method hex(num) {
    var s := ""
    while {num > 0} do {
        var i := num % 16
        s := s ++ hexdigits.at(i + 1)
        num := num - i
        num := num / 16
    }
    s
}

method join(joiner, iterable) {
    def ind = iterable.indices
    def min = ind.first
    var s := ""
    for (ind) do {i->
        if (i != min) then {
            s := s ++ joiner
        }
        s := s ++ iterable.at(i)
    }
    s
}
