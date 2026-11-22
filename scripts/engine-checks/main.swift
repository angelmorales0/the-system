import Foundation
let problems = EngineChecks.run() + (await HevyRoutine.checkWrites())
for problem in problems { print("FAIL \(problem)") }
print(problems.isEmpty ? "ENGINE CHECKS PASSED" : "ENGINE CHECKS FAILED: \(problems.count)")
exit(problems.isEmpty ? 0 : 1)
