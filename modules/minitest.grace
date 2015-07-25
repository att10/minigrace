import "gUnit" as gu

inherits prelude.methods

var currentTestSuiteForDialect := done
var currentSetupBlockForTesting := done
var currentTestBlockForTesting := 0
var currentTestInThisEvaluation := 0

def mtAssertion = object {
    inherits gu.assertion.trait
    var currentResult is writable := object {
        method countOneAssertion {
            print "countOneAssertion requested on dummy result"
        }
    }

    method countOneAssertion {
        currentResult.countOneAssertion
    }
}

method assert(bb:Boolean) description(str:String) {
    mtAssertion.assert(bb)description(str)
}

method deny(bb:Boolean) description(str:String) {
    mtAssertion.deny(bb)description(str)
}

method assert(bb:Boolean) {
    mtAssertion.assert(bb)
}

method deny(bb:Boolean) {
    mtAssertion.deny(bb)
}

method assert(s1:Object) shouldBe (s2:Object) {
    mtAssertion.assert(s1)shouldBe(s2)
}

method assert(s1:Object) shouldntBe (s2:Object) {
    mtAssertion.assert(s1) shouldntBe (s2)
}

method assert(n1:Number) shouldEqual (n2:Number) within (epsilon:Number) {
    mtAssertion.assert(n1) shouldEqual (n2) within (epsilon)
}

method assert(b:Block) shouldRaise(de:Exception) {
    mtAssertion.assert(b)shouldRaise(de)
}

method assert(b:Block) shouldntRaise(ue:Exception) {
    mtAssertion.assert(b)shouldntRaise(ue)
}

method assert(s:Object) hasType (t:Type) {
    mtAssertion.assert(s) hasType (t)
}

method deny(s:Object) hasType (UndesiredType) {
    mtAssertion.deny(s) hasType (UndesiredType)
}

method failBecause(reason) {
    mtAssertion.assert(false) description(reason)
}

method testSuite(block:Block) {
    if(currentTestSuiteForDialect != done) then {
        Exception.raise("a testSuite cannot be created inside a testSuite")
    }
    currentTestSuiteForDialect := gu.testSuite.empty
    currentSetupBlockForTesting := block
    currentTestInThisEvaluation := 0
    block.apply()
    currentSetupBlockForTesting := done
    currentTestSuiteForDialect.runAndPrintResults()
    currentTestSuiteForDialect := done
    currentTestBlockForTesting := 0
}

method test(name:String) by(block:Block) {
    if(currentTestSuiteForDialect == done) then {
        Exception.raise("a test can be created only within a testSuite")
    }
    currentTestInThisEvaluation := currentTestInThisEvaluation + 1
    if(currentSetupBlockForTesting != done) then {
        currentTestSuiteForDialect.add(testCaseNamed(name)
            setupIn(currentSetupBlockForTesting)
            asTestNumber(currentTestInThisEvaluation))
    } else {
        if(currentTestInThisEvaluation == currentTestBlockForTesting) then {
            block.apply()
        }
    }
}

method testCaseNamed(name') setupIn(setupBlock) asTestNumber(number) -> gu.TestCase {
    object {
        inherits gu.testCaseNamed(name')

        method setup { 
            super.setup
            currentTestBlockForTesting := number
            currentTestInThisEvaluation := 0
            setupBlock.apply
        }

        method teardown {
            currentTestBlockForTesting := 0
        }

        method run (result) {
            mtAssertion.currentResult := result
            result.testStarted(name)
            try {
                try {
                    setup
                } finally { 
                    teardown
                }
            } catch {e: self.AssertionFailure ->
                result.testFailed(name)withMessage(e.message)
            } catch {e: Exception ->
                result.testErrored(name)withMessage "{e.exception}: {e.message}"
            }
            result.testFinished(name)
        }

        method debug (result) {
            mtAssertion.currentResult := result
            result.testStarted(name)
            try {
                print ""
                print "debugging test {name} ..."
                try {
                    setup
                } finally { 
                    teardown
                }
            } catch {e: self.AssertionFailure ->
                result.testFailed(name)withMessage(e.message)
                printBackTrace(e) limitedTo(name)
            } catch {e: Exception ->
                result.testErrored(name)withMessage(e.message)
                printBackTrace(e) limitedTo(name)
            }
            result.testFinished(name)
        }
    }
}
