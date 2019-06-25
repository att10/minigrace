import "ast" as ast
import "collectionsPrelude" as collections
inherit prelude.methods

def suggestions  = collections.list.empty

def typeVisitor = object {
    inherit ast.baseVisitor
    method asString {
        "the requireTypes visitor"
    }

    method visitDefDec(v) -> Boolean is public {
        if (false == v.dtype) then {
            suggestions.add(v)
        }
        true
    }
    method visitVarDec(v) -> Boolean is public {
        if (false == v.dtype) then {
            suggestions.add(v)
        }
        true
    }
    method visitMethod(v) -> Boolean is public {
        for (v.signature) do {p ->
            if (p.isIdentifier && {p.wildcard.not && (false == p.dtype)}) then {
                suggestions.add(p)
            }
        }
        if (false == v.dtype) then {
            suggestions.add(v)
        }
        true
    }
    method visitBlock(v) -> Boolean is public {
        for (v.params) do {p ->
            if (p.isIdentifier && {p.wildcard.not && (false == p.dtype)}) then {
                 suggestions.add(p)
            }
        }
        true
    }
}

def thisDialect is public = object {
    method parseChecker (moduleObj) -> collections.List {
        suggestions.clear
        moduleObj.accept(typeVisitor)
        suggestions
    }
}